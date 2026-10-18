import 'package:clippy/core/vision/imagenet_groups.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a dog breed also reads as "dog"', () {
    expect(imagenetLabels('kelpie', 227), ['kelpie', 'dog', 'pet']);
  });

  test('a sports car reads as "car"', () {
    expect(imagenetLabels('sports car', 817), containsAll(['car', 'vehicle']));
  });

  test('an unmapped class keeps just its own name', () {
    expect(imagenetLabels('hourglass', 604), ['hourglass']);
  });
}
