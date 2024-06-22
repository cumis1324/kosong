import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

const INDEX_URLS = [
  'https://drive.nfgplusmirror.workers.dev/1:/Movie/',
  'https://drive2.nfgplusmirror.workers.dev/0:/Movie/',
  'https://drive3.nfgplusmirror.workers.dev/0:/Movie/'
  // Add more index URLs as needed
];
const TMDB_API_KEY = '75399494372c92bd800f70079dff476b';
const FIREBASE_PROJECT_ID = 'nfgview-160c7';
const FIREBASE_API_KEY = 'AIzaSyCiFlbEyGtH7ijFWUFBhRtTE1EDICqHw3o';
const FIREBASE_COLLECTION = 'movies';

Future<void> handleRequest() async {
  String nextPageToken = '';
  int pageIndex = 0;

  for (final indexUrl in INDEX_URLS) {
    nextPageToken = '';
    pageIndex = 0;
    bool hasNextPage = true;

    while (hasNextPage) {
      final data = await fetchScraperData(indexUrl, nextPageToken, pageIndex);
      final files = data['data']['files'];

      for (final file in files) {
        if (file['mimeType'] != 'application/vnd.google-apps.folder') {
          final extractedData = extractNameAndQuality(file['name']);
          if (extractedData != null) {
            try {
              final tmdbData = await fetchTmdbData(extractedData['name']!, extractedData['year']!, TMDB_API_KEY);
              if (tmdbData != null && tmdbData.isNotEmpty) {
                await storeToFirestore(
                  tmdbData,
                  extractedData['name']!,
                  extractedData['year']!,
                  file['name'],
                  indexUrl + Uri.encodeComponent(file['name']),
                  file['modifiedTime'],
                  file['size'],
                  file['mimeType'],
                  extractedData['qualityName']!,
                  extractedData['qualityVideo']!
                );
                print('Added Movie ${extractedData['name']} (${extractedData['year']})');
              } else {
                print('No movie found for ${extractedData['name']} (${extractedData['year']})');
              }
            } catch (e) {
              print('Error fetching TMDB data for ${extractedData['name']} (${extractedData['year']}): $e');
            }
          }
        }
      }

      if (data.containsKey('nextPageToken')) {
        nextPageToken = data['nextPageToken'];
        pageIndex++;
      } else {
        hasNextPage = false;
      }
    }
  }

  print('Data processing complete');
}

Future<Map<String, dynamic>> fetchScraperData(String url, String nextPageToken, int pageIndex) async {
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
}

String decryptResponse(String response) {
  final reversedResponse = response.split('').reversed.join('');
  final encodedString = reversedResponse.substring(24, reversedResponse.length - 20);
  return utf8.decode(base64.decode(encodedString));
}

Future<Map<String, dynamic>> fetchTmdbData(String name, String year, String apiKey) async {
  final tmdbUrl = 'https://api.themoviedb.org/3/search/movie?api_key=$apiKey&query=${Uri.encodeComponent(name)}&include_adult=false&language=en-US&primary_release_year=${Uri.encodeComponent(year)}&page=1';
  final response = await http.get(Uri.parse(tmdbUrl));

  if (response.statusCode != 200) {
    throw Exception('Failed to fetch TMDB data for query $name');
  }

  final data = jsonDecode(response.body);
  if (data['results'] != null && data['results'].isNotEmpty) {
    return data['results'][0];
  } else {
    return {}; // Return empty map if no results found
  }
}

Future<void> storeToFirestore(Map<String, dynamic> movieData, String extractedName, String extractedYear, String filename, String filenameUrl, String filenameModifiedTime, String filenameSize, String mimeType, String qualityName, String qualityVideo) async {
  final movieId = movieData['id'].toString();
  final firestoreUrl = 'https://firestore.googleapis.com/v1/projects/$FIREBASE_PROJECT_ID/databases/(default)/documents/$FIREBASE_COLLECTION/$movieId?key=$FIREBASE_API_KEY';

  final payload = {
    'fields': {
      'id': {'integerValue': movieData['id']},
      'title': {'stringValue': movieData['title']},
      'genre_ids': {
        'arrayValue': {
          'values': movieData['genre_ids'].map((id) => {'integerValue': id}).toList()
        }
      },
      'original_language': {'stringValue': movieData['original_language']},
      'original_title': {'stringValue': movieData['original_title']},
      'popularity': {'doubleValue': movieData['popularity']},
      'vote_count': {'integerValue': movieData['vote_count']},
      'vote_average': {'doubleValue': movieData['vote_average']},
      'overview': {'stringValue': movieData['overview']},
      'release_date': {'stringValue': movieData['release_date']},
      'poster_path': {'stringValue': 'https://image.tmdb.org/t/p/w500${movieData['poster_path']}'},
      'backdrop_path': {'stringValue': 'https://image.tmdb.org/t/p/w1280${movieData['backdrop_path']}'},
      'filenames': {
        'arrayValue': {
          'values': [
            {
              'mapValue': {
                'fields': {
                  'filename': {'stringValue': filename},
                  'filename_url': {'stringValue': filenameUrl},
                  'mimeType': {'stringValue': mimeType},
                  'qualityName': {'stringValue': qualityName},
                  'qualityVideo': {'stringValue': qualityVideo},
                  'size': {'stringValue': filenameSize},
                  'lastModified': {'stringValue': filenameModifiedTime},
                }
              }
            }
          ]
        }
      }
    }
  };

  final response = await http.patch(
    Uri.parse(firestoreUrl),
    headers: {
      'Content-Type': 'application/json',
    },
    body: jsonEncode(payload),
  );

  if (response.statusCode != 200) {
    throw Exception('Failed to store data in Firestore');
  }
}

Map<String, String>? extractNameAndQuality(String filename) {
  final regExp = RegExp(r'(\d+)\.(.*?)\.(\d{4})\.(\d+p)(?:\.NF)?\.(.*?)\..*', caseSensitive: false);
  final match = regExp.firstMatch(filename);
  if (match != null) {
    final name = match.group(1)?.replaceAll('.', ' '); // Replace dots with spaces
    final year = match.group(2);
    final qualityVideo = match.group(3);
    final qualityName = match.group(4);
    if (name != null && year != null && qualityVideo != null && qualityName != null) {
      return {
        'name': name.trim(),
        'year': year,
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
