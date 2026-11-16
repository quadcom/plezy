import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/plezyfin_titles.dart';

/// PlezyFin's outside-the-library answers (PLAN_PFN_114 / 115), field names as
/// the plezyfin session gave them on 2026-11-15.
void main() {
  group('person page', () {
    final page = PlezyFinPersonPage.fromJson({
      'Person': {
        'Id': 'p1',
        'Name': 'Sam Rockwell',
        'ProfileUrl': 'https://image.tmdb.org/t/p/w500/sam.jpg',
        'Biography': 'An American actor.',
        'Birthday': '1968-11-05',
        'Deathday': null,
        'PlaceOfBirth': 'Daly City, California, USA',
        'KnownForDepartment': 'Acting',
        'TmdbId': 6807,
      },
      'Credits': [
        {
          'MediaType': 'movie',
          'TmdbId': 243688,
          'Title': 'Poltergeist',
          'Year': 2015,
          'Role': 'cast',
          'Character': 'Eric Bowen',
          'Popularity': 20.5,
          'ItemId': 'lib-1',
          'RequestState': 'available',
        },
        {
          'MediaType': 'movie',
          'TmdbId': 17431,
          'Title': 'Moon',
          'Year': 2009,
          'Role': 'cast',
          'Character': 'Sam Bell',
          'Popularity': 30,
          'ItemId': null,
          'RequestState': 'none',
        },
        {
          'MediaType': 'movie',
          'TmdbId': 359940,
          'Title': 'Three Billboards Outside Ebbing, Missouri',
          'Year': 2017,
          'Role': 'crew',
          'Job': 'Thanks',
          'Popularity': 25,
        },
        {
          'MediaType': 'movie',
          'TmdbId': 359940,
          'Title': 'Three Billboards Outside Ebbing, Missouri',
          'Year': 2017,
          'Role': 'cast',
          'Character': 'Dixon',
          'Popularity': 25,
        },
        {
          'MediaType': 'tv',
          'TmdbId': 59941,
          'Title': 'The Tonight Show Starring Jimmy Fallon',
          'Year': 2014,
          'Role': 'cast',
          'Character': 'Self',
          'EpisodeCount': 3,
          'Popularity': 90,
        },
        {'MediaType': 'person', 'TmdbId': 1, 'Title': 'skipped'},
      ],
      'CanRequest': true,
      'Message': null,
    });

    test('reads the person and their age', () {
      final person = page.person!;
      expect(person.name, 'Sam Rockwell');
      expect(person.birthday, DateTime(1968, 11, 5));
      expect(person.ageOn(DateTime(2026, 11, 4)), 57);
      expect(person.ageOn(DateTime(2026, 11, 5)), 58);
      expect(person.placeOfBirth, 'Daly City, California, USA');
      expect(page.canRequest, isTrue);
    });

    test('drops credits it cannot read', () {
      expect(page.credits, hasLength(5));
      expect(page.credits.last.kind, MediaKind.show);
      expect(page.credits.last.episodeCount, 3);
    });

    test('Known for: not in the library, one per title, no talk-show selves, most popular first', () {
      final knownFor = page.knownFor;
      expect(knownFor.map((t) => t.title), ['Moon', 'Three Billboards Outside Ebbing, Missouri']);
      // The acting credit wins over the crew one for the same film.
      expect(knownFor[1].character, 'Dixon');
    });

    test('age at death', () {
      final person = PlezyFinPerson.fromJson({'Name': 'Someone', 'Birthday': '1930-05-31', 'Deathday': '2000-05-30'})!;
      expect(person.ageOn(DateTime(2026, 1, 1)), 69);
    });
  });

  group('search and title', () {
    test('search results and upcoming dates', () {
      final search = PlezyFinTitleSearch.fromJson({
        'CanRequest': true,
        'Results': [
          {
            'MediaType': 'movie',
            'TmdbId': 1,
            'Title': 'Future Film',
            'ReleaseDate': '2027-05-01',
            'RequestState': 'requested',
          },
          {'MediaType': 'tv', 'TmdbId': 2, 'Title': 'Old Show', 'ReleaseDate': '1999-01-01', 'ItemId': 'x'},
        ],
      });
      expect(search.results, hasLength(2));
      final film = search.results.first;
      expect(film.year, 2027);
      expect(film.isUpcoming(DateTime(2026, 11, 15)), isTrue);
      expect(film.isUpcoming(DateTime(2027, 5, 1)), isFalse);
      expect(film.requestState, PlezyFinRequestState.requested);
      expect(film.requestState!.canAsk, isFalse);
      expect(search.results.last.inLibrary, isTrue);
    });

    test('a title becomes an Explore item with its tmdb id', () {
      final title = PlezyFinTitle.fromJson({'MediaType': 'tv', 'TmdbId': 59941, 'Title': 'A Show', 'Year': 2014})!;
      final item = title.toCatalogItem(genres: ['Comedy']);
      expect(item.kind, MediaKind.show);
      expect(item.ids.tmdb, 59941);
      expect(item.genres, ['Comedy']);
    });

    test('title details carry cast, genres and runtime', () {
      final detail = PlezyFinTitleDetail.fromJson({
        'Title': {
          'MediaType': 'movie',
          'TmdbId': 609,
          'Title': 'Poltergeist',
          'Genres': ['Horror', ''],
          'Runtime': 114,
          'Certification': 'PG',
          'Cast': [
            {'Name': 'JoBeth Williams', 'Character': 'Diane Freeling', 'ProfileUrl': 'https://x/y.jpg'},
            {'Character': 'nameless'},
          ],
        },
        'CanRequest': false,
      });
      expect(detail.title!.tmdbId, 609);
      expect(detail.genres, ['Horror']);
      expect(detail.runtimeMinutes, 114);
      expect(detail.cast.single.secondary, 'Diane Freeling');
      expect(detail.canRequest, isFalse);
    });
  });

  test('a documentary narrated by its own director stays in Known for through the crew credit', () {
    // Live shape (Alex Gibney, 2026-11-15): cast "Self - Narrator" plus a Director credit; null fields left out.
    final page = PlezyFinPersonPage.fromJson({
      'Person': {'Name': 'Alex Gibney', 'KnownForDepartment': 'Directing'},
      'Credits': [
        {
          'MediaType': 'movie',
          'TmdbId': 214083,
          'Title': 'The Armstrong Lie',
          'Year': 2013,
          'Role': 'cast',
          'Character': 'Self - Narrator',
          'Popularity': 2.1,
        },
        {
          'MediaType': 'movie',
          'TmdbId': 214083,
          'Title': 'The Armstrong Lie',
          'Year': 2013,
          'Role': 'crew',
          'Job': 'Director',
          'Popularity': 2.1,
        },
      ],
      'CanRequest': true,
    });
    expect(page.knownFor.single.job, 'Director');
    expect(page.message, isNull);
  });

  test("the bio loses TMDb's Wikipedia credit line", () {
    // Live text (Rachel Brosnahan, SHIELD screenshot 2026-11-16), shortened.
    final person = PlezyFinPerson.fromJson({
      'Name': 'Rachel Brosnahan',
      'Biography':
          'Rachel Brosnahan is an American actress.\n\nOn stage, she made her Broadway debut in 2013.\n\n'
          'Description above from the Wikipedia article Rachel Brosnahan, licensed under CC-BY-SA, full list of '
          'contributors on Wikipedia.',
    })!;
    expect(
      person.biography,
      'Rachel Brosnahan is an American actress.\n\nOn stage, she made her Broadway debut in 2013.',
    );
    expect(PlezyFinPerson.cleanBiography('Description above from the Wikipedia article X.'), isNull);
    expect(PlezyFinPerson.cleanBiography('Plain bio.'), 'Plain bio.');
  });

  group('request result', () {
    test('success and refusals', () {
      final ok = PlezyFinRequestResult.fromJson({'Ok': true, 'RequestState': 'processing'}, statusCode: 200);
      expect(ok.ok, isTrue);
      expect(ok.requestState, PlezyFinRequestState.processing);

      final refused = PlezyFinRequestResult.fromJson({
        'Ok': false,
        'Message': 'Requests are not switched on for this account.',
      }, statusCode: 403);
      expect(refused.ok, isFalse);
      expect(refused.message, contains('not switched on'));

      final bare = PlezyFinRequestResult.fromJson('Already in the library.', statusCode: 409);
      expect(bare.message, 'Already in the library.');
    });
  });
}
