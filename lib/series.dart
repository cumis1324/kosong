import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

const INDEX_URLS = [
  'https://drive2.nfgplusmirror.workers.dev/0:/Series/'
  // Add more index URLs as needed
];
const TMDB_API_KEY = '75399494372c92bd800f70079dff476b';
const FIREBASE_PROJECT_ID = 'nfgview-160c7';
const FIREBASE_API_KEY = 'AIzaSyCiFlbEyGtH7ijFWUFBhRtTE1EDICqHw3o';
const FIREBASE_COLLECTION = 'series';

Future<void> handleRequest() async {
  String nextPageToken = '';
  int pageIndex = 0;

  for (final indexUrl in INDEX_URLS) {
    nextPageToken = '';
    pageIndex = 0;
    bool hasNextPage = true;

    while (hasNextPage) {
      try {
        final data = await fetchScraperData(indexUrl, nextPageToken, pageIndex);
        if (data == null || !data.containsKey('data') || !data['data'].containsKey('files')) {
          throw Exception('Invalid data structure received from $indexUrl');
        }

        final files = data['data']['files'];

        for (final file in files) {
          if (file != null && file['mimeType'] != null && file['mimeType'] != 'application/vnd.google-apps.folder') {
            final extractedData = extractNameAndQuality(file['name']);
            if (extractedData != null) {
              try {
                final tmdbData = await fetchTmdbData(extractedData['name']!, extractedData['seasonNumber']!, TMDB_API_KEY);
                if (tmdbData.isNotEmpty) {
                  await storeToFirestore(
                    tmdbData,
                    extractedData['seasonNumber']!,
                    extractedData['episode']!,
                    file['name'],
                    indexUrl + Uri.encodeComponent(file['name']),
                    file['modifiedTime'] ?? '',
                    file['size'] ?? '',
                    file['mimeType'] ?? '',
                    extractedData['qualityName']!,
                    extractedData['qualityVideo']!
                  );
                  print('Added File ${file['name']} to Firestore');
                } else {
                  print('No TMDB data found for ${extractedData['name']} (${extractedData['seasonNumber']})');
                }
              } catch (e) {
                print('Error fetching TMDB data for ${extractedData['name']} (${extractedData['seasonNumber']}): $e');
              }
            }
          }
        }

        if (data.containsKey('nextPageToken')) {
          nextPageToken = data['nextPageToken'] ?? '';
          pageIndex++;
        } else {
          hasNextPage = false;
        }
      } catch (e) {
        print('Error processing index URL $indexUrl: $e');
        hasNextPage = false; // Stop processing further pages on error
      }
    }
  }

  print('Data processing complete');
}

Future<Map<String, dynamic>?> fetchScraperData(String url, String nextPageToken, int pageIndex) async {
  try {
    final response = await http.post(
      Uri.parse(url),
      headers: {
        HttpHeaders.contentTypeHeader: 'application/x-www-form-urlencoded',
      },
      body: {
        'page_token': nextPageToken,
        'page_index': pageIndex.toString(),
      },
    );

    if (response.statusCode != 200) {
      if (response.statusCode == 404) {
        throw Exception('Resource not found: $url');
      } else {
        throw Exception('Request failed with status ${response.statusCode}');
      }
    }

    final encryptedResponse = response.body;
    final decryptedResponse = decryptResponse(encryptedResponse);
    return jsonDecode(decryptedResponse);
  } catch (e) {
    print('Error fetching scraper data for $url: $e');
    return null;
  }
}

String decryptResponse(String response) {
  final reversedResponse = response.split('').reversed.join('');
  final encodedString = reversedResponse.substring(24, reversedResponse.length - 20);
  return utf8.decode(base64.decode(encodedString));
}

Future<Map<String, dynamic>> fetchTmdbData(String name, String seasonNumber, String apiKey) async {
  final tmdbUrl = 'https://api.themoviedb.org/3/search/tv?api_key=$apiKey&query=${Uri.encodeComponent(name)}&include_adult=false&language=en-US&page=1';
  final response = await http.get(Uri.parse(tmdbUrl));

  if (response.statusCode != 200) {
    throw Exception('Failed to fetch TMDB data for query $name');
  }

  final data = jsonDecode(response.body);
  if (data['results'] != null && data['results'].isNotEmpty) {
    final seriesId = data['results'][0]['id'];
    final tmdbSeasonData = await fetchTmdbSeasonData(seriesId.toString(), seasonNumber, apiKey);
    return {
      'seriesId': seriesId.toString(),
      'seasonId': tmdbSeasonData['id'].toString(),
      'seasonData': tmdbSeasonData,
    };
  } else {
    throw Exception('No TMDB results found for query $name');
  }
}

Future<Map<String, dynamic>> fetchTmdbSeasonData(String seriesId, String seasonNumber, String apiKey) async {
  final tmdbUrl = 'https://api.themoviedb.org/3/tv/$seriesId/season/$seasonNumber?api_key=$apiKey';
  final response = await http.get(Uri.parse(tmdbUrl));

  if (response.statusCode != 200) {
    throw Exception('Failed to fetch TMDB season data for series ID $seriesId and season number $seasonNumber');
  }

  return jsonDecode(response.body);
}

Future<void> storeToFirestore(Map<String, dynamic> tmdbData, String seasonNumber, String episodeNumber, String filename, String filenameUrl, String filenameModifiedTime, String filenameSize, String mimeType, String qualityName, String qualityVideo) async {
  final seriesId = tmdbData['seriesId'];
  final seasonId = tmdbData['seasonId'];
  final episodeId = findEpisodeId(tmdbData['seasonData']['episodes'], episodeNumber);

  final firestoreUrl = 'https://firestore.googleapis.com/v1/projects/$FIREBASE_PROJECT_ID/databases/(default)/documents/$FIREBASE_COLLECTION/$seriesId/$seasonId/$episodeId/filenames';

  final payload = {
    'fields': {
      'filenames': {
        'arrayValue': {
          'values': [
            {
              'mapValue': {
                'fields': {
                  'filename_url': {'stringValue': filenameUrl},
                  'mimeType': {'stringValue': mimeType},
                  'qualityName': {'stringValue': qualityName},
                  'qualityVideo': {'stringValue': qualityVideo},
                  'size': {'stringValue': filenameSize},
                  'lastModified': {'stringValue': filenameModifiedTime},
                },
              },
            },
          ],
        },
      },
    },
  };

  final response = await http.patch(
    Uri.parse(firestoreUrl),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $FIREBASE_API_KEY',
    },
    body: jsonEncode(payload),
  );

  if (response.statusCode != 200) {
    throw Exception('Failed to store data in Firestore');
  }
}

String findEpisodeId(List<dynamic> episodes, String episodeNumber) {
  for (final episode in episodes) {
    final episodeNumberStr = episode['episode_number']?.toString();
    final episodeId = episode['id']?.toString();

    if (episodeNumberStr == episodeNumber && episodeId != null) {
      return episodeId;
    }
  }

  // Handle case where no matching episode ID is found
  throw Exception('Episode $episodeNumber not found in the episodes list.');
}

Map<String, String>? extractNameAndQuality(String filename) {
  final regExp = RegExp(
    r'(?:(\d+)\.)?(.*?)\.S?(\d{1,2})\.(E\d{1,2})\.(\d+p)(?:\.(?:NF|DNSP|AMZN))?\.(.*?)\..*',
    caseSensitive: false,
  );
  final match = regExp.firstMatch(filename);
  
  if (match != null) {
    final initialDigits = match.group(1);
    final name = '${initialDigits ?? ''} ${match.group(2)?.replaceAll('.', ' ')}'.trim(); // Concatenate and replace dots with spaces
    final seasonNumber = match.group(3); // Numeric part of season (1)
    final episode = match.group(4)?.substring(1); // Episode info (E1) - remove 'E' prefix
    final qualityVideo = match.group(5); // Quality (720p)
    final qualityName = match.group(6); // Remaining info (Blueray, etc.)

    if ((initialDigits != null || match.group(2) != null) && seasonNumber != null && episode != null && qualityVideo != null && qualityName != null) {
      return {
        'name': name.trim(),
        'seasonNumber': seasonNumber,
        'episode': episode,
        'qualityVideo': qualityVideo,
        'qualityName': qualityName
      };
    }
  }

  return null;
}

void main() {
  handleRequest().catchError((error) {
    print('Error: $error');
  });
}
