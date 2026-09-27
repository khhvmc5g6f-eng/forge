// Verifies the inline NN engine extracted from live-3d-nn/index.html.
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('../../web_lab/index.html', import.meta.url), 'utf8');
const start = html.indexOf('/*ENGINE-START*/');
const end = html.indexOf('/*ENGINE-END*/');
if (start < 0 || end < 0 || end < start) throw new Error('engine markers not found');
// The marker sits inside a `//` comment line; skip to the next line.
const engineSrc = html.slice(html.indexOf('\n', start) + 1, end);
const engine = new Function(engineSrc + `
  return { mulberry32, makeDataset, splitTrainTest, MLP };
`)();
const { makeDataset, splitTrainTest, MLP } = engine;

let failures = 0;
const check = (name, cond, detail = '') => {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${detail ? ' — ' + detail : ''}`);
  if (!cond) failures++;
};

// ---- Test 1: numerical gradient check ------------------------------------
// Compare analytic backprop gradients against central finite differences.
function gradCheck() {
  const net = new MLP([2, 5, 4, 1], { activation: 'tanh', lr: 0.0, seed: 123 });
  const batch = [{ x: 0.3, y: -0.7, label: 1 }, { x: -0.4, y: 0.55, label: 0 },
                 { x: 0.8, y: 0.2, label: 0 }, { x: -0.1, y: -0.9, label: 1 }];
  const eps = 1e-5;
  let maxRelErr = 0;
  for (let l = 0; l < net.L; l++) {
    for (let k = 0; k < net.W[l].length; k++) {
      const orig = net.W[l][k];
      // analytic: run one step at lr=0 (gradients accumulated, no update)
      net.trainStep(batch);
      const g = net.dW[l][k] / batch.length;
      net.W[l][k] = orig; // restore (trainStep didn't move weights since lr=0)
      // numeric
      net.W[l][k] = orig + eps;
      const lp = net.lossAndAcc(batch).loss;
      net.W[l][k] = orig - eps;
      const lm = net.lossAndAcc(batch).loss;
      net.W[l][k] = orig;
      const num = (lp - lm) / (2 * eps);
      const rel = Math.abs(g - num) / Math.max(1e-8, Math.abs(num) + Math.abs(g));
      maxRelErr = Math.max(maxRelErr, rel);
      if (maxRelErr > 1e-3) return { ok: false, maxRelErr };
    }
  }
  return { ok: maxRelErr < 1e-3, maxRelErr };
}
const gc = gradCheck();
check('backprop gradients match numerical differentiation', gc.ok,
      `max relative error ${gc.maxRelErr.toExponential(2)}`);

// Also check ReLU variant (kinks avoided by picking generic samples).
{
  const net = new MLP([2, 6, 1], { activation: 'relu', lr: 0.0, seed: 9 });
  const batch = [{ x: 0.5, y: 0.5, label: 1 }, { x: -0.5, y: -0.3, label: 0 }];
  let maxRelErr = 0;
  for (let l = 0; l < net.L; l++) {
    for (let k = 0; k < net.W[l].length; k++) {
      const orig = net.W[l][k];
      net.trainStep(batch);
      const g = net.dW[l][k] / batch.length;
      net.W[l][k] = orig;
      const eps = 1e-5;
      net.W[l][k] = orig + eps;
      const lp = net.lossAndAcc(batch).loss;
      net.W[l][k] = orig - eps;
      const lm = net.lossAndAcc(batch).loss;
      net.W[l][k] = orig;
      const num = (lp - lm) / (2 * eps);
      const rel = Math.abs(g - num) / Math.max(1e-8, Math.abs(num) + Math.abs(g));
      maxRelErr = Math.max(maxRelErr, rel);
    }
  }
  check('ReLU backprop matches numerical gradients', maxRelErr < 5e-3,
        `max relative error ${maxRelErr.toExponential(2)}`);
}

// ---- Test 2: dataset sanity -----------------------------------------------
for (const name of ['spiral', 'moons', 'circles', 'xor', 'gauss']) {
  const pts = makeDataset(name, 400, 0.15, 7);
  const counts = pts.reduce((acc, p) => (acc[p.label]++, acc), [0, 0]);
  const inRange = pts.every(p => Math.abs(p.x) <= 2.5 && Math.abs(p.y) <= 2.5);
  check(`dataset "${name}" is balanced & bounded`, counts[0] === counts[1] && inRange,
        `${pts.length} pts, classes [${counts}]`);
}

// ---- Test 3: training convergence on the hardest dataset (spiral, Adam) --
{
  const pts = makeDataset('spiral', 400, 0.15, 7);
  const { train, test } = splitTrainTest(pts, 0.25, 8);
  const net = new MLP([7, 8, 8, 1], {
    activation: 'tanh', optimizer: 'adam', features: 'extended', lr: 0.01, seed: 3,
  });
  const startLoss = net.lossAndAcc(train).loss;
  let loss = startLoss;
  for (let step = 0; step < 6000; step++) {
    const batch = [];
    for (let i = 0; i < 16; i++) batch.push(train[(Math.random() * train.length) | 0]);
    loss = net.trainStep(batch).loss;
  }
  const finalAcc = net.lossAndAcc(test).acc;
  check('spiral (Adam + engineered features): loss decreases', loss < startLoss * 0.3,
        `${startLoss.toFixed(3)} → ${loss.toFixed(3)}`);
  check('spiral (Adam + engineered features): test accuracy > 90%', finalAcc > 0.9,
        `acc ${(finalAcc * 100).toFixed(1)}%`);
}

// ---- Test 3b: pedagogy — engineered features beat raw (x, y) on spiral --
{
  const pts = makeDataset('spiral', 400, 0.15, 7);
  const { train, test } = splitTrainTest(pts, 0.25, 8);
  const run = (features, nIn) => {
    const net = new MLP([nIn, 8, 8, 1], {
      activation: 'tanh', optimizer: 'adam', features, lr: 0.01, seed: 3,
    });
    for (let step = 0; step < 6000; step++) {
      const batch = [];
      for (let i = 0; i < 16; i++) batch.push(train[(Math.random() * train.length) | 0]);
      net.trainStep(batch);
    }
    return net.lossAndAcc(test).acc;
  };
  const rawAcc = run('basic', 2);
  const extAcc = run('extended', 7);
  check('spiral: engineered features beat raw (x, y)', extAcc > rawAcc,
        `raw ${(rawAcc * 100).toFixed(1)}% < engineered ${(extAcc * 100).toFixed(1)}%`);
}

// ---- Test 4: all datasets learnable (Adam) ---------------------------------
for (const name of ['moons', 'circles', 'xor', 'gauss']) {
  const pts = makeDataset(name, 400, 0.15, 7);
  const { train, test } = splitTrainTest(pts, 0.25, 8);
  const net = new MLP([2, 8, 8, 1], { activation: 'tanh', optimizer: 'adam', lr: 0.01, seed: 3 });
  for (let step = 0; step < 2500; step++) {
    const batch = [];
    for (let i = 0; i < 16; i++) batch.push(train[(Math.random() * train.length) | 0]);
    net.trainStep(batch);
  }
  const acc = net.lossAndAcc(test).acc;
  check(`"${name}" (Adam): test accuracy > 85%`, acc > 0.85, `acc ${(acc * 100).toFixed(1)}%`);
}

// ---- Test 4b: plain SGD still converges (moons) ---------------------------
{
  const pts = makeDataset('moons', 400, 0.15, 7);
  const { train, test } = splitTrainTest(pts, 0.25, 8);
  const net = new MLP([2, 10, 8, 1], { activation: 'tanh', optimizer: 'sgd', lr: 0.1, seed: 3 });
  for (let step = 0; step < 1500; step++) {
    const batch = [];
    for (let i = 0; i < 16; i++) batch.push(train[(Math.random() * train.length) | 0]);
    net.trainStep(batch);
  }
  const acc = net.lossAndAcc(test).acc;
  check('moons (SGD): test accuracy > 85%', acc > 0.85, `acc ${(acc * 100).toFixed(1)}%`);
}

// ---- Test 5: param count ---------------------------------------------------
{
  const net = new MLP([2, 8, 8, 1], { activation: 'tanh', lr: 0.03 });
  // (2*8+8)+(8*8+8)+(8*1+1) = 24+72+9 = 105
  check('paramCount is correct', net.paramCount === 105, `${net.paramCount} params`);
}

console.log(failures === 0 ? '\nALL ENGINE TESTS PASSED' : `\n${failures} TEST(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
