/// Everyday words for ImageNet classes. The Windows classifier (MobileNetV2)
/// names 1000 fine classes: it calls a dog "kelpie" or "golden retriever",
/// and nobody searches for that. These ranges of the standard class order
/// add the word people do type ("dog", "cat", "car"...).
library;

const _ranges = <(int, int, List<String>)>[
  (0, 6, ['fish']),
  (7, 24, ['bird']),
  (25, 32, ['animal']),
  (33, 37, ['turtle', 'animal']),
  (38, 48, ['lizard', 'animal']),
  (49, 51, ['crocodile', 'animal']),
  (52, 68, ['snake', 'animal']),
  (69, 79, ['spider', 'insect']),
  (80, 100, ['bird']),
  (118, 126, ['crab', 'seafood']),
  (127, 146, ['bird']),
  (147, 150, ['sea animal']),
  (151, 268, ['dog', 'pet']),
  (269, 280, ['wolf', 'fox', 'animal']),
  (281, 285, ['cat', 'pet']),
  (286, 293, ['big cat', 'animal']),
  (294, 297, ['bear', 'animal']),
  (300, 326, ['insect']),
  (330, 332, ['rabbit', 'pet']),
  (333, 338, ['animal']),
  (339, 364, ['animal']),
  (365, 384, ['monkey', 'animal']),
  (389, 397, ['fish']),
  (924, 969, ['food']),
  (948, 957, ['fruit']),
];

const _single = <int, List<String>>{
  407: ['car', 'vehicle'],
  436: ['car', 'vehicle'],
  468: ['car', 'taxi', 'vehicle'],
  511: ['car', 'vehicle'],
  609: ['car', 'vehicle'],
  627: ['car', 'vehicle'],
  656: ['car', 'vehicle'],
  661: ['car', 'vehicle'],
  717: ['car', 'truck', 'vehicle'],
  751: ['car', 'vehicle'],
  817: ['car', 'vehicle'],
  444: ['bicycle', 'bike'],
  671: ['bicycle', 'bike'],
  670: ['scooter', 'vehicle'],
  487: ['phone'],
  528: ['phone'],
  707: ['phone'],
  527: ['computer'],
  590: ['computer'],
  620: ['laptop', 'computer'],
  681: ['laptop', 'computer'],
  664: ['screen', 'monitor'],
  782: ['screen'],
  851: ['tv', 'screen'],
  916: ['website', 'screenshot'],
  921: ['book'],
  922: ['menu', 'food'],
  549: ['envelope', 'letter'],
  404: ['plane', 'airplane'],
  895: ['plane', 'airplane'],
  779: ['bus', 'vehicle'],
  874: ['bus', 'vehicle'],
  466: ['train'],
  547: ['train'],
  565: ['train'],
  820: ['train'],
  978: ['beach'],
  970: ['mountain'],
  980: ['mountain'],
  973: ['sea', 'reef'],
  975: ['lake'],
};

/// The fine label plus everyday words for ImageNet class [index], without
/// duplicates; [fine] first so the most specific word still matches best.
List<String> imagenetLabels(String fine, int index) {
  final out = <String>[fine];
  void add(Iterable<String> words) {
    for (final w in words) {
      if (!out.contains(w)) out.add(w);
    }
  }

  for (final (from, to, words) in _ranges) {
    if (index >= from && index <= to) add(words);
  }
  final one = _single[index];
  if (one != null) add(one);
  return out;
}
