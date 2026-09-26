import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/tools/command_classifier.dart';
import 'package:forge/core/tools/tool_category.dart';

void main() {
  final classifier = CommandClassifier();

  group('CommandClassifier', () {
    test('classifies read-only git/status commands as safe', () {
      expect(classifier.classify('git status'), CommandRisk.safe);
      expect(classifier.classify('flutter analyze'), CommandRisk.safe);
      expect(classifier.classify('ls -la'), CommandRisk.safe);
    });

    test('classifies read commands', () {
      expect(classifier.classify('git diff'), CommandRisk.read);
      expect(classifier.classify('git log'), CommandRisk.read);
    });

    test('classifies build/test/install', () {
      expect(classifier.classify('flutter build macos'), CommandRisk.build);
      expect(classifier.classify('flutter test'), CommandRisk.test);
      expect(classifier.classify('npm install'), CommandRisk.install);
    });

    test('classifies modify commands', () {
      expect(classifier.classify('git commit -m "x"'), CommandRisk.modify);
      expect(classifier.classify('mv a b'), CommandRisk.modify);
    });

    test('classifies destructive commands regardless of flag order', () {
      expect(classifier.classify('rm -rf /tmp/x'), CommandRisk.destructive);
      expect(classifier.classify('rm -fr /tmp/x'), CommandRisk.destructive);
      expect(classifier.classify('git push --force origin main'), CommandRisk.destructive);
      expect(classifier.classify('git reset --hard HEAD~1'), CommandRisk.destructive);
    });

    test('classifies privileged commands', () {
      expect(classifier.classify('sudo rm file'), CommandRisk.privileged);
    });

    test('unknown commands default to modify, never safe', () {
      expect(classifier.classify('some-totally-unknown-tool --wipe'), CommandRisk.modify);
    });
  });
}
