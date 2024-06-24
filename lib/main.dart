import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mongo_dart/mongo_dart.dart' as mongo;

const INDEX_URLS = [
  'https://drive.nfgplusmirror.workers.dev/1:/Movie/',
  'https://drive2.nfgplusmirror.workers.dev/0:/Movie/',
  'https://drive3.nfgplusmirror.workers.dev/0:/Movie/'
  // Add more index URLs as needed
];
const TMDB_API_KEY = '75399494372c92bd800f70079dff476b';
const MONGO_DB_URL = 'mongodb+srv://cekitbro:huntupeda@nfgweb.13spjec.mongodb.net/?retryWrites=true&w=majority&appName=nfgweb';
const MONGO_DB_NAME = 'nfgweb';
const MONGO_COLLECTION_NAME = 'movies';

Future<void> handleRequest() async {
  String nextPageToken = '';
  int pageIndex = 0;

  final db = await mongo.Db.create(MONGO_DB_URL);
  
  try {
    await db.open();
    final collection = db.collection(MONGO_COLLECTION_NAME);

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
                  await storeToMongoDB(
                    collection,
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
  } catch (e) {
    print('Error connecting to MongoDB: $e');
  } finally {
    await db.close();
    print('Data processing complete');
  }
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

Future<void> storeToMongoDB(
  mongo.DbCollection collection,
  Map<String, dynamic> movieData,
  String extractedName,
  String extractedYear,
  String filename,
  String filenameUrl,
  String filenameModifiedTime,
  String filenameSize,
  String mimeType,
  String qualityName,
  String qualityVideo
) async {
  final movieId = movieData['id'].toString();

  final document = {
    'id': movieData['id'],
    'title': movieData['title'],
    'genre_ids': movieData['genre_ids'],
    'original_language': movieData['original_language'],
    'original_title': movieData['original_title'],
    'popularity': movieData['popularity'],
    'vote_count': movieData['vote_count'],
    'vote_average': movieData['vote_average'],
    'overview': movieData['overview'],
    'release_date': movieData['release_date'],
    'poster_path': 'https://image.tmdb.org/t/p/w500${movieData['poster_path']}',
    'backdrop_path': 'https://image.tmdb.org/t/p/w1280${movieData['backdrop_path']}',
    'filenames': [
      {
        'filename': filename,
        'filename_url': filenameUrl,
        'mimeType': mimeType,
        'qualityName': qualityName,
        'qualityVideo': qualityVideo,
        'size': filenameSize,
        'lastModified': filenameModifiedTime,
      }
    ]
  };

  await collection.updateOne(
    mongo.where.eq('id', movieData['id']),
    mongo.modify.set('id', movieData['id'])
                  .set('title', movieData['title'])
                  .set('genre_ids', movieData['genre_ids'])
                  .set('original_language', movieData['original_language'])
                  .set('original_title', movieData['original_title'])
                  .set('popularity', movieData['popularity'])
                  .set('vote_count', movieData['vote_count'])
                  .set('vote_average', movieData['vote_average'])
                  .set('overview', movieData['overview'])
                  .set('release_date', movieData['release_date'])
                  .set('poster_path', 'https://image.tmdb.org/t/p/w500${movieData['poster_path']}')
                  .set('backdrop_path', 'https://image.tmdb.org/t/p/w1280${movieData['backdrop_path']}')
                  .set('filenames', [
                    {
                      'filename': filename,
                      'filename_url': filenameUrl,
                      'mimeType': mimeType,
                      'qualityName': qualityName,
                      'qualityVideo': qualityVideo,
                      'size': filenameSize,
                      'lastModified': filenameModifiedTime,
                    }
                  ]),
    upsert: true,
  );
}

Map<String, String>? extractNameAndQuality(String filename) {
  final regExp = RegExp(r'(?:(\d+)\.)?(.*?)\.(\d{4})\.(\d+p)(?:\.(?:NF|DNSP|AMZN))?\.(.*?)\..*', caseSensitive: false);
  final match = regExp.firstMatch(filename);
  
  if (match != null) {
    final initialDigits = match.group(1);
    final name = '${initialDigits ?? ''} ${match.group(2)?.replaceAll('.', ' ')}'.trim(); // Concatenate and replace dots with spaces
    final year = match.group(3);
    final qualityVideo = match.group(4);

    final qualityName = match.group(5);

    if ((initialDigits != null || match.group(2) != null) && year != null && qualityVideo != null && qualityName != null) {
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
