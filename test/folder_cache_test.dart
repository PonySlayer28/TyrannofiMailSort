import 'package:flutter_test/flutter_test.dart';
import 'package:tyrannofi_app/services/storage_service.dart';

void main() {
  const ttl = Duration(hours: 24);
  // A plausible wall clock: 2026-08-03.
  const now = 1785000000000;

  group('folderCacheIsFresh', () {
    test('a fresh entry is believed', () {
      expect(folderCacheIsFresh(now - 1000, now, ttl), isTrue);
      expect(folderCacheIsFresh(now, now, ttl), isTrue);
    });

    test('an entry past the TTL is not', () {
      expect(folderCacheIsFresh(now - ttl.inMilliseconds, now, ttl), isFalse);
      expect(folderCacheIsFresh(now - ttl.inMilliseconds * 2, now, ttl),
          isFalse);
    });

    test('an invalidated entry is never believed, whatever the clock says', () {
      // The promise Fehler 11 rests on. An invalidated entry carries ts 0, and
      // seeding `known` or `created` from folders a merge deleted would skip
      // the CREATE and strand every mail heading there — silently.
      for (final clock in [now, 0 + ttl.inMilliseconds, 1 << 40]) {
        expect(folderCacheIsFresh(0, clock, ttl), isFalse,
            reason: 'ts 0 was treated as fresh at $clock');
      }
    });
  });

  group('staleFolderCacheEntry', () {
    test('keeps the folders and drops the timestamp', () {
      final entry = staleFolderCacheEntry({
        'ts': now,
        'folders': [
          {'name': 'Amazon', 'count': 12},
        ],
      });
      expect(entry['ts'], 0);
      expect(entry['folders'], hasLength(1));
    });

    test('so the strict read refuses it and allowStale still gets a list', () {
      final entry = staleFolderCacheEntry({
        'ts': now,
        'folders': [
          {'name': 'Amazon', 'count': 12},
        ],
      });
      expect(folderCacheIsFresh(entry['ts'] as int, now, ttl), isFalse);
      expect((entry['folders'] as List), isNotEmpty);
    });

    test('survives an entry that never had a list', () {
      expect(staleFolderCacheEntry({'ts': now})['folders'], isEmpty);
    });
  });
}
