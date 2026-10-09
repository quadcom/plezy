import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_course.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_role.dart';
import 'package:plezy/media/media_trailer.dart';

void main() {
  group('courseKey', () {
    // Real guids from Plex section 26 (PMB's provider), read 2026-10-08.
    test('reads the course from a Plex show, season and lesson guid', () {
      const show = PlexMediaItem(
        id: '111085',
        kind: MediaKind.show,
        guid: 'tv.plex.agents.custom.pmb.masterclass://show/pc-mc60',
      );
      const season = PlexMediaItem(
        id: '111086',
        kind: MediaKind.season,
        guid: 'tv.plex.agents.custom.pmb.masterclass://season/pc-mc60-s1',
      );
      const lesson = PlexMediaItem(
        id: '111087',
        kind: MediaKind.episode,
        guid: 'tv.plex.agents.custom.pmb.masterclass://episode/pc-mc60-e1',
      );
      expect(show.courseKey, 'pc-mc60');
      expect(season.courseKey, 'pc-mc60');
      expect(lesson.courseKey, 'pc-mc60');
      expect(show.isCourse, isTrue);
    });

    test('ignores ordinary Plex shows', () {
      const show = PlexMediaItem(id: '1', kind: MediaKind.show, guid: 'plex://show/5d9c086c46115600200aa2fe');
      expect(show.courseKey, isNull);
      expect(show.isCourse, isFalse);
    });

    test('reads the course from a Jellyfin series ProviderIds', () {
      const series = JellyfinMediaItem(
        id: 'abc',
        kind: MediaKind.show,
        raw: {
          'ProviderIds': {'Tvdb': '1', 'PmbMasterClass': 'pc-mc60'},
        },
      );
      const plain = JellyfinMediaItem(
        id: 'def',
        kind: MediaKind.show,
        raw: {
          'ProviderIds': {'Tvdb': '1'},
        },
      );
      expect(series.courseKey, 'pc-mc60');
      expect(plain.courseKey, isNull);
    });
  });

  group('courseInstructors', () {
    test('takes the people PMB names as Instructor', () {
      const course = PlexMediaItem(
        id: '1',
        kind: MediaKind.show,
        roles: [
          MediaRole(tag: 'Alex Honnold', role: 'Instructor'),
          MediaRole(tag: 'Tommy Caldwell', role: 'instructor'),
          MediaRole(tag: 'Someone Else', role: 'Narrator'),
        ],
      );
      expect(course.courseInstructors, ['Alex Honnold', 'Tommy Caldwell']);
    });
  });

  group('splitCourseTitle', () {
    test('splits "<instructor> Teaches <subject>"', () {
      final split = splitCourseTitle('Aaron Franklin Teaches Texas Style BBQ');
      expect(split.instructor, 'Aaron Franklin');
      expect(split.subject, 'Texas Style BBQ');
    });

    test('splits "<instructors> Teach <subject>"', () {
      final split = splitCourseTitle('Alex Honnold & Tommy Caldwell Teach Rock Climbing');
      expect(split.instructor, 'Alex Honnold & Tommy Caldwell');
      expect(split.subject, 'Rock Climbing');
    });

    test('splits "<subject> with <instructor>"', () {
      final split = splitCourseTitle('Bake Like a Pro With Joanne Chang');
      expect(split.instructor, 'Joanne Chang');
      expect(split.subject, 'Bake Like a Pro');
    });

    test('drops a dash before "With"', () {
      final split = splitCourseTitle('AI Strategy at Work - With Amy Webb Featuring Nichol Bradford');
      expect(split.instructor, 'Amy Webb Featuring Nichol Bradford');
      expect(split.subject, 'AI Strategy at Work');
    });

    test('keeps the whole title when it names nobody', () {
      final split = splitCourseTitle('Mastering Negotiation');
      expect(split.instructor, isEmpty);
      expect(split.subject, 'Mastering Negotiation');
    });

    test('prefers the instructors PMB supplies', () {
      final split = splitCourseTitle('The Dealmaker\'s Mindset with Super Agent Rich Paul', instructors: ['Rich Paul']);
      expect(split.instructor, 'Rich Paul');
      expect(split.subject, 'The Dealmaker\'s Mindset');
    });

    test('removes a supplied instructor from a "Teaches" title', () {
      final split = splitCourseTitle('Aaron Franklin Teaches Texas Style BBQ', instructors: ['Aaron Franklin']);
      expect(split.instructor, 'Aaron Franklin');
      expect(split.subject, 'Texas Style BBQ');
    });
  });

  group('courseSummary', () {
    test('drops PMB\'s leading Folder line', () {
      const raw =
          'Folder: Aaron Franklin Teaches Texas Style BBQ [pmb-mc60]\n\nMeet your new instructor: Aaron Franklin.';
      expect(courseSummary(raw), 'Meet your new instructor: Aaron Franklin.');
    });

    test('leaves other summaries alone', () {
      expect(courseSummary('Folders and files explained.'), 'Folders and files explained.');
      expect(courseSummary(null), isNull);
    });
  });

  group('pickTrailer', () {
    const course = PlexMediaItem(id: 's', kind: MediaKind.show);

    test('picks the extra marked as a trailer', () {
      const extras = [
        PlexMediaItem(id: 'a', kind: MediaKind.clip, subtype: 'behindTheScenes'),
        PlexMediaItem(id: 'b', kind: MediaKind.clip, subtype: 'trailer'),
      ];
      expect(pickTrailer(course, extras)?.id, 'b');
    });

    test('prefers the primary extra Plex names', () {
      const named = PlexMediaItem(id: 's', kind: MediaKind.show, trailerKey: '/library/metadata/c');
      const extras = [
        PlexMediaItem(id: 'b', kind: MediaKind.clip, subtype: 'trailer'),
        PlexMediaItem(id: 'c', kind: MediaKind.clip, subtype: 'trailer'),
      ];
      expect(pickTrailer(named, extras)?.id, 'c');
    });

    test('reads the Jellyfin trailer type', () {
      const extras = [
        JellyfinMediaItem(id: 'j', kind: MediaKind.clip, raw: {'Type': 'Trailer', 'ExtraType': 'Trailer'}),
      ];
      expect(pickTrailer(course, extras)?.id, 'j');
    });

    test('is null without a trailer', () {
      expect(pickTrailer(course, const []), isNull);
      expect(pickTrailer(course, const [PlexMediaItem(id: 'a', kind: MediaKind.clip, subtype: 'interview')]), isNull);
    });
  });
}
