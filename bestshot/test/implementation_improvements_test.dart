import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:bestshot/src/services/analysis/embedding_cache.dart';
import 'package:bestshot/src/models/exif_summary.dart';
import 'package:bestshot/src/services/grouping/grouping.dart';
import 'package:bestshot/src/services/grouping/temporal_candidate_index.dart';
import 'grouping_modes_test.dart' show photo;

void main() {
  test(
    'time index exactly matches exhaustive search including unknown timestamps',
    () {
      final random = Random(11);
      final items = List.generate(
        150,
        (i) => photo(
          '$i',
          seconds: i % 13 == 0 ? null : random.nextInt(20000) - 10000,
        ),
      );
      final index = TemporalCandidateIndex(items);
      for (var i = 0; i < items.length; i++) {
        final expected = <int>{};
        for (var j = 0; j < items.length; j++) {
          final a = items[i].capturedAt;
          final b = items[j].capturedAt;
          if (i != j &&
              (a == null ||
                  b == null ||
                  a.difference(b).inMilliseconds.abs() <= 600000)) {
            expected.add(j);
          }
        }
        expect(index.candidates(i, subjectMode: false).toSet(), expected);
        expect(index.candidates(i, subjectMode: true).length, items.length - 1);
      }
    },
  );

  test('burst classification preserves subsecond boundary', () {
    final a = photo('a');
    final b = photo('b').copyWith(
      exif: () => ExifSummary(
        fNumber: null,
        shutter: null,
        iso: null,
        capturedAt: a.capturedAt!.add(const Duration(milliseconds: 15500)),
      ),
    );
    // Strong visual evidence joins the scene, but sixteen seconds is not a
    // fifteen-second burst (do not truncate the fractional second).
    final groups = PhotoGrouper.group([a, b], const GroupingConfig());
    expect(groups.every((group) => !group.isBurst), isTrue);
  });

  test(
    'duplicate photo keys and unsafe keep count are rejected explicitly',
    () {
      expect(
        () => PhotoGrouper.group([
          photo('a'),
          photo('a'),
        ], const GroupingConfig()),
        throwsArgumentError,
      );
      expect(
        () => PhotoGrouper.group([
          photo('a'),
        ], const GroupingConfig(autoDeleteKeepTopN: 0)),
        throwsArgumentError,
      );
    },
  );

  group('embedding cache', () {
    late Directory temp;
    late File source;
    late EmbeddingCache cache;
    Map<String, Float32List> vectors() => {
      for (final key in ['full', 'center', 'left', 'right'])
        key: Float32List(576)..[0] = 1,
    };
    setUp(() async {
      temp = await Directory.systemTemp.createTemp('bestshot_cache_test_');
      source = File('${temp.path}/photo.jpg');
      await source.writeAsBytes([1, 2, 3]);
      cache = EmbeddingCache(Directory('${temp.path}/cache'), 'model-v1', true);
    });
    tearDown(() async {
      await temp.delete(recursive: true);
    });

    test('round trip, source modification and replacement overwrite', () async {
      final original = cache.fingerprint(source.path, await source.stat());
      await cache.write(source.path, original, vectors());
      expect((await cache.read(source.path, original))?['full']?.length, 576);
      await source.writeAsBytes([1, 2, 3, 4]);
      final changed = cache.fingerprint(source.path, await source.stat());
      expect(await cache.read(source.path, changed), isNull);
      await cache.write(source.path, changed, vectors());
      expect(await cache.read(source.path, changed), isNotNull);
      expect(await cache.directory.list().length, 1);
    });

    test('model and crop policy changes invalidate the cache', () async {
      final key = cache.fingerprint(source.path, await source.stat());
      await cache.write(source.path, key, vectors());
      final updatedModel = EmbeddingCache(cache.directory, 'model-v2', true);
      expect(
        await updatedModel.read(
          source.path,
          updatedModel.fingerprint(source.path, await source.stat()),
        ),
        isNull,
      );
      final desktop = EmbeddingCache(cache.directory, 'model-v1', false);
      expect(
        await desktop.read(
          source.path,
          desktop.fingerprint(source.path, await source.stat()),
        ),
        isNull,
      );
    });

    test(
      'corrupt, non-normalized and invalid-dimensional cache is ignored',
      () async {
        final key = cache.fingerprint(source.path, await source.stat());
        final invalid = vectors()..['full'] = Float32List(576);
        await cache.write(source.path, key, invalid);
        expect(await cache.read(source.path, key), isNull);
        await cache.write(
          source.path,
          key,
          vectors()..['full'] = Float32List(5),
        );
        expect(await cache.read(source.path, key), isNull);
        final file = (await cache.directory.list().toList()).single as File;
        await file.writeAsString('{bad-json');
        expect(await cache.read(source.path, key), isNull);
      },
    );
  });
}
