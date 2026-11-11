// 职责: 验证 OpenAI Videos 协议的官方/Agnes 双方言编解码、轮询路由与下载凭据边界。
// 关联文件:
//   lib/shared/services/ai/video/openai_videos.dart
//   lib/shared/services/ai/video/client.dart
//   lib/shared/models/video/channels.dart
//   lib/shared/models/video/catalog.dart
//   lib/shared/models/video/task_result.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/models/video/task_result.dart';
import 'package:reveric/shared/services/ai/video/openai_videos.dart';

final _endpoint = Uri.parse('https://example.com/proxy/v1');

OpenAIVideosClient client(String providerType, http.Client transport) =>
    OpenAIVideosClient(
      httpClient: transport,
      providerType: providerType,
      endpoint: _endpoint,
      apiKey: 'secret',
    );

http.Client noNetwork() =>
    MockClient((_) => throw StateError('must not send'));

VideoRequest official({
  String model = 'sora-2',
  String prompt = 'A bird flying',
  String resolution = '720p',
  String ratio = '16:9',
  int duration = 4,
  VideoMode mode = VideoMode.text,
  bool? audio,
  bool? promptExtend,
}) => VideoRequest(
  modelId: model,
  prompt: prompt,
  mode: mode,
  resolution: resolution,
  ratio: ratio,
  durationSeconds: duration,
  audio: audio,
  promptExtend: promptExtend,
);

VideoRequest agnes({
  String model = 'agnes-video-2.5',
  String resolution = '720P',
  String ratio = '16:9',
  int duration = 5,
  VideoMode mode = VideoMode.text,
}) => VideoRequest(
  modelId: model,
  prompt: 'A bird flying',
  mode: mode,
  resolution: resolution,
  ratio: ratio,
  durationSeconds: duration,
);

VideoReference ref(VideoInputRole role) => VideoReference(
  role: role,
  url: 'https://reference.example/${role.name}',
  mimeType: switch (role.kind) {
    VideoMediaKind.image => 'image/png',
    VideoMediaKind.video => 'video/mp4',
    VideoMediaKind.audio => 'audio/mpeg',
  },
  fileSize: 100,
  mediaInfo: const VideoMediaInfo(
    width: 720,
    height: 720,
    durationMs: 2000,
    frameRate: 30,
  ),
);

VideoSubmission submission(String taskId) => VideoSubmission(
  taskId: taskId,
  modelId: 'sora-2',
  pollingUrl: _endpoint.replace(path: '${_endpoint.path}/videos/$taskId'),
);

void main() {
  group('official Sora dialect', () {
    test('encodes seconds as string, WxH size and one input_reference', () {
      final api = client('openai', noNetwork());
      expect(api.encode(official(), []), {
        'model': 'sora-2',
        'prompt': 'A bird flying',
        'seconds': '4',
        'size': '1280x720',
      });
      expect(
        api.encode(official(mode: VideoMode.first_frame), [
          ref(VideoInputRole.first_frame),
        ]),
        {
          'model': 'sora-2',
          'prompt': 'A bird flying',
          'seconds': '4',
          'size': '1280x720',
          'input_reference': 'https://reference.example/first_frame',
        },
      );
    });

    test('covers all four documented Sora size enums', () {
      final api = client('openai', noNetwork());
      for (final (resolution, ratio, expected) in [
        ('720p', '16:9', '1280x720'),
        ('720p', '9:16', '720x1280'),
        ('1080p', '16:9', '1792x1024'),
        ('1080p', '9:16', '1024x1792'),
      ]) {
        expect(
          api.encode(
            official(
              model: 'sora-2-pro',
              resolution: resolution,
              ratio: ratio,
            ),
            [],
          )['size'],
          expected,
          reason: '$resolution $ratio',
        );
      }
      expect(
        () => api.encode(official(resolution: '2K'), []),
        throwsA(
          isA<VideoException>().having(
            (e) => e.field,
            'field',
            'resolution',
          ),
        ),
      );
    });

    test('rejects unsupported modes, audio and reference combinations', () {
      final api = client('openai', noNetwork());
      for (final request in [
        official(prompt: ''),
        official(audio: true),
        official(promptExtend: false),
        official(mode: VideoMode.reference),
        official(mode: VideoMode.first_last_frame),
      ]) {
        expect(
          () => api.encode(request, []),
          throwsA(isA<VideoException>()),
        );
      }
      expect(
        () => api.encode(official(), [ref(VideoInputRole.first_frame)]),
        throwsA(isA<VideoException>()),
      );
      expect(
        () => api.encode(official(mode: VideoMode.first_frame), []),
        throwsA(isA<VideoException>()),
      );
      expect(
        () => api.encode(official(mode: VideoMode.first_frame), [
          ref(VideoInputRole.first_frame),
          ref(VideoInputRole.last_frame),
        ]),
        throwsA(isA<VideoException>()),
      );
    });
  });

  group('Agnes dialect', () {
    test('encodes explicit mode, aspect ratio and resolution tier', () {
      final api = client('openai_compatible', noNetwork());
      expect(api.encode(agnes(), []), {
        'model': 'agnes-video-2.5',
        'prompt': 'A bird flying',
        'seconds': '5',
        'size': '720P',
        'aspect_ratio': '16:9',
        'mode': 'text',
      });
    });

    test('flattens keyframes and groups reference media by role', () {
      final api = client('openai_compatible', noNetwork());
      expect(
        api.encode(agnes(mode: VideoMode.first_last_frame), [
          ref(VideoInputRole.first_frame),
          ref(VideoInputRole.last_frame),
        ]),
        {
          'model': 'agnes-video-2.5',
          'prompt': 'A bird flying',
          'seconds': '5',
          'size': '720P',
          'aspect_ratio': '16:9',
          'mode': 'keyframe',
          'first_frame': 'https://reference.example/first_frame',
          'last_frame': 'https://reference.example/last_frame',
        },
      );
      expect(
        api.encode(agnes(mode: VideoMode.reference), [
          ref(VideoInputRole.reference_image),
          ref(VideoInputRole.reference_audio),
          ref(VideoInputRole.reference_video),
        ]),
        {
          'model': 'agnes-video-2.5',
          'prompt': 'A bird flying',
          'seconds': '5',
          'size': '720P',
          'aspect_ratio': '16:9',
          'mode': 'reference',
          'images': ['https://reference.example/reference_image'],
          'audios': ['https://reference.example/reference_audio'],
          'videos': [
            {'url': 'https://reference.example/reference_video'},
          ],
        },
      );
    });

    test('flash stays on the dialect while unregistered Sora stays official', () {
      final api = client('openai_compatible', noNetwork());
      expect(api.encode(agnes(model: 'agnes-video-2.5-flash'), []), {
        'model': 'agnes-video-2.5-flash',
        'prompt': 'A bird flying',
        'seconds': '5',
        'size': '720P',
        'aspect_ratio': '16:9',
        'mode': 'text',
      });
      // openai_compatible 的覆盖表整表优先，未登记的 Sora 回退官方方言。
      expect(api.encode(official(), [])['size'], '1280x720');
    });
  });

  group('submission ID across gateways', () {
    test('prefers gateway job_id and never falls back to video_id', () {
      final api = client('openai', noNetwork());
      expect(api.submissionId({'id': 'task-1'}), 'task-1');
      expect(
        api.submissionId({
          'id': 'task_1',
          'task_id': 'task_1',
          'video_id': 'video_long',
        }),
        'task_1',
      );
      // agnes2api 纯透传上游回执，没有自有 ID。
      expect(
        api.submissionId({'task_id': 'task_2', 'video_id': 'video_long'}),
        'task_2',
      );
      // agnes-hub-go 的轮询路由 JobByID 只认自有 job_id。
      expect(
        api.submissionId({
          'job_id': 'job_1',
          'id': 'task_1',
          'task_id': 'task_1',
          'video_id': 'video_long',
        }),
        'job_1',
      );
      for (final Map<String, dynamic> json in [
        <String, dynamic>{},
        {'video_id': 'video_long'},
        {'id': '  '},
      ]) {
        expect(() => api.submissionId(json), throwsFormatException);
      }
    });

    test('missing task ID is submission_unknown and never resubmits', () async {
      var posts = 0;
      final api = client(
        'openai',
        MockClient((_) async {
          posts++;
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        api.submit(official(), []),
        throwsA(
          isA<VideoException>().having(
            (e) => e.code,
            'code',
            VideoErrorCode.submission_unknown,
          ),
        ),
      );
      expect(posts, 1);
    });
  });

  group('result decoding', () {
    test('maps all upstream status words including completed', () {
      final api = client('openai', noNetwork());
      for (final (status, expected) in [
        ('queued', VideoRemoteStatus.queued),
        ('pending', VideoRemoteStatus.queued),
        ('in_progress', VideoRemoteStatus.running),
        ('completed', VideoRemoteStatus.succeeded),
        ('failed', VideoRemoteStatus.failed),
        ('cancelled', VideoRemoteStatus.cancelled),
        ('expired', VideoRemoteStatus.expired),
        ('UNKNOWN', VideoRemoteStatus.unknown),
      ]) {
        expect(
          api.decodeResult({
            'id': 'task-1',
            'status': status,
            'url': 'https://result.example/movie.mp4',
          }).status,
          expected,
          reason: status,
        );
      }
    });

    test('prefers public URLs and falls back to authenticated /content', () {
      final api = client('openai', noNetwork());
      for (final json in [
        {'url': 'https://result.example/a.mp4'},
        {'video_url': 'https://result.example/b.mp4'},
        {
          'metadata': {'url': 'https://result.example/c.mp4'},
        },
      ]) {
        expect(
          api.decodeResult({
            'id': 'task-1',
            'status': 'completed',
            ...json,
          }).videoUrl.toString(),
          startsWith('https://result.example/'),
        );
      }
      expect(
        api.decodeResult({'id': 'task-1', 'status': 'completed'}).videoUrl
            .toString(),
        'https://example.com/proxy/v1/videos/task-1/content',
      );
    });

    test('ignores unusable URL placeholders and uses the gateway job ID', () {
      final api = client('openai_compatible', noNetwork());
      for (final bad in [
        '/relative/movie.mp4',
        'ftp://result.example/movie.mp4',
        'https://user:pass@result.example/movie.mp4',
        'mailto:someone@example.com',
      ]) {
        expect(
          api.decodeResult({
            'id': 'task-1',
            'status': 'completed',
            'url': bad,
          }).videoUrl.toString(),
          'https://example.com/proxy/v1/videos/task-1/content',
          reason: bad,
        );
      }
      expect(
        api.decodeResult({
          'job_id': 'job_1',
          'id': 'task_1',
          'status': 'completed',
        }).videoUrl.toString(),
        'https://example.com/proxy/v1/videos/job_1/content',
      );
    });
  });

  group('routing compatible with sub2api / new-api', () {
    test('official submit and poll stay on /v1/videos/{id}', () async {
      final seen = <http.Request>[];
      final transport = MockClient((r) async {
        seen.add(r);
        if (r.method == 'POST') {
          return http.Response(jsonEncode({'id': 'task-1'}), 200);
        }
        return http.Response(
          jsonEncode({
            'id': 'task-1',
            'status': 'completed',
          }),
          200,
        );
      });
      final api = client('openai', transport);
      final task = await api.submit(official(), []);
      expect(task.taskId, 'task-1');
      expect(
        task.pollingUrl.toString(),
        'https://example.com/proxy/v1/videos/task-1',
      );
      expect(seen.first.url.toString(), 'https://example.com/proxy/v1/videos');
      expect(seen.first.headers['Authorization'], 'Bearer secret');
      expect(jsonDecode(seen.first.body), {
        'model': 'sora-2',
        'prompt': 'A bird flying',
        'seconds': '4',
        'size': '1280x720',
      });
      final result = await api.query(task);
      expect(result.status, VideoRemoteStatus.succeeded);
      expect(
        result.videoUrl.toString(),
        'https://example.com/proxy/v1/videos/task-1/content',
      );
      expect(seen.last.method, 'GET');
      expect(
        seen.last.url.toString(),
        'https://example.com/proxy/v1/videos/task-1',
      );
      expect(seen.last.url.path, isNot(contains('agnesapi')));
    });

    test('agnes-hub-go receipt polls its own job_id on /v1/videos/{id}', () async {
      final seen = <http.Request>[];
      final transport = MockClient((r) async {
        seen.add(r);
        if (r.method == 'POST') {
          return http.Response(
            jsonEncode({
              'job_id': 'job_1',
              'id': 'task_1',
              'task_id': 'task_1',
              'video_id': 'video_long',
              'poll_url': 'https://example.com/proxy/v1/videos/job_1',
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'job_id': 'job_1',
            'id': 'task_1',
            'status': 'completed',
            'url': 'https://result.example/movie.mp4',
          }),
          200,
        );
      });
      final api = client('openai_compatible', transport);
      final task = await api.submit(agnes(), []);
      expect(task.taskId, 'job_1');
      final result = await api.query(task);
      expect(result.status, VideoRemoteStatus.succeeded);
      expect(result.videoUrl.toString(), 'https://result.example/movie.mp4');
      expect(
        seen.last.url.toString(),
        'https://example.com/proxy/v1/videos/job_1',
      );
      expect(seen.first.url.toString(), 'https://example.com/proxy/v1/videos');
      expect(jsonDecode(seen.first.body)['mode'], 'text');
      expect(jsonDecode(seen.first.body)['size'], '720P');
    });

    test('direct Agnes / agnes2api passthrough polls task_id', () async {
      final seen = <http.Request>[];
      final transport = MockClient((r) async {
        seen.add(r);
        if (r.method == 'POST') {
          return http.Response(
            jsonEncode({
              'id': 'task_1',
              'task_id': 'task_1',
              'video_id': 'video_long',
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'id': 'task_1',
            'task_id': 'task_1',
            'status': 'in_progress',
          }),
          200,
        );
      });
      final api = client('openai_compatible', transport);
      final task = await api.submit(agnes(), []);
      expect(task.taskId, 'task_1');
      expect(
        (await api.query(task)).status,
        VideoRemoteStatus.running,
      );
      expect(
        seen.last.url.toString(),
        'https://example.com/proxy/v1/videos/task_1',
      );
    });

    test('changed polling URL is rejected before sending credentials', () async {
      final api = client('openai', noNetwork());
      await expectLater(
        api.query(
          VideoSubmission(
            taskId: 'task-1',
            modelId: 'sora-2',
            pollingUrl: Uri.parse('https://foreign.example/videos/task-1'),
          ),
        ),
        throwsA(
          isA<VideoException>().having(
            (e) => e.code,
            'code',
            VideoErrorCode.configuration_required,
          ),
        ),
      );
    });
  });

  group('download credential boundary', () {
    test('content endpoint receives the key only on the first hop', () async {
      final seen = <http.Request>[];
      final transport = MockClient((r) async {
        seen.add(r);
        if (seen.length == 1) {
          return http.Response(
            '',
            302,
            headers: {'location': 'https://cdn.example/movie.mp4'},
          );
        }
        return http.Response('bytes', 200);
      });
      final api = client('openai', transport);
      final response = await api.download(
        transport,
        api.url('videos/task-1/content'),
        submission('task-1'),
      );
      expect(response.statusCode, 200);
      expect(seen.length, 2);
      expect(seen.first.headers['Authorization'], 'Bearer secret');
      expect(seen.last.url.toString(), 'https://cdn.example/movie.mp4');
      expect(seen.last.headers.containsKey('Authorization'), false);
    });

    test('plain http redirect targets are rejected', () async {
      var requests = 0;
      final transport = MockClient((r) async {
        requests++;
        return http.Response(
          '',
          302,
          headers: {'location': 'http://cdn.example/movie.mp4'},
        );
      });
      final api = client('openai', transport);
      await expectLater(
        api.download(
          transport,
          api.url('videos/task-1/content'),
          submission('task-1'),
        ),
        throwsA(
          isA<VideoException>().having(
            (e) => e.code,
            'code',
            VideoErrorCode.invalid_response,
          ),
        ),
      );
      expect(requests, 1);
    });

    test('public gateway URL and foreign host never inherit the key', () async {
      final seen = <http.Request>[];
      final transport = MockClient((r) async {
        seen.add(r);
        return http.Response('bytes', 200);
      });
      final api = client('openai_compatible', transport);
      for (final target in [
        'https://cdn.example/movie.mp4',
        'https://foreign.example/proxy/v1/videos/task-1/content',
      ]) {
        await api.download(
          transport,
          Uri.parse(target),
          submission('task-1'),
        );
      }
      expect(seen.length, 2);
      for (final request in seen) {
        expect(request.headers.containsKey('Authorization'), false);
      }
    });
  });
}
