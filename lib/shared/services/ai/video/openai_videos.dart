// 职责: 编解码 OpenAI Videos 协议任务，在官方方言与 Agnes 方言间按目录型号分派。
// 关联文件:
//   lib/shared/services/ai/video/client.dart
//   lib/shared/models/video/channels.dart
//   lib/shared/models/video/request.dart
//   lib/shared/models/video/task_result.dart

import 'package:http/http.dart' as http;

import '../../../models/video/channels.dart';
import '../../../models/video/request.dart';
import '../../../models/video/task_result.dart';
import 'client.dart';

/// OpenAI Videos 协议客户端。轮询固定走 `GET /v1/videos/{id}`，与 OpenAI
/// 官方、sub2api、new-api 等网关路由兼容；成片地址优先取轮询响应的公开
/// URL，官方方言无 URL 时改用带凭据的 /content 端点取片。
class OpenAIVideosClient extends VideoClient {
  OpenAIVideosClient({
    required super.httpClient,
    required super.providerType,
    required super.endpoint,
    required super.apiKey,
    super.timeout,
  });

  @override
  String get createPath => 'videos';
  @override
  String queryPath(String id) => 'videos/$id';

  bool _isAgnes(VideoRequest request) =>
      lookupVideoChannelModel(providerType, request.modelId)?.catalogId
          .startsWith('agnes-video-') ==
      true;

  @override
  Map<String, dynamic> encode(
    VideoRequest request,
    List<VideoReference> references,
  ) {
    if (request.prompt.trim().isEmpty || request.durationSeconds <= 0) {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'prompt',
      );
    }
    return _isAgnes(request)
        ? _encodeAgnes(request, references)
        : _encodeOpenAI(request, references);
  }

  /// OpenAI 官方方言：size 是 WxH 枚举，参考图为单个 input_reference。
  Map<String, dynamic> _encodeOpenAI(
    VideoRequest request,
    List<VideoReference> references,
  ) {
    if ((request.mode != VideoMode.text &&
            request.mode != VideoMode.first_frame) ||
        references.length > 1 ||
        references.any((ref) => ref.role != VideoInputRole.first_frame) ||
        (request.mode == VideoMode.text && references.isNotEmpty) ||
        (request.mode == VideoMode.first_frame && references.length != 1)) {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'references',
      );
    }
    if (request.audio != null || request.promptExtend != null) {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'audio',
      );
    }
    return {
      'model': request.modelId,
      'prompt': request.prompt,
      'seconds': '${request.durationSeconds}',
      'size': _officialSize(request.resolution, request.ratio),
      if (references.isNotEmpty)
        'input_reference': references.single.url.toString(),
    };
  }

  /// Sora 官方尺寸枚举：720p 两档 + pro 的 1080p 档位（1792x1024 等 7:4 形状，
  /// 无法从分辨率推导，必须查显式表）。
  String _officialSize(String resolution, String ratio) =>
      switch ((resolution.toLowerCase(), ratio)) {
        ('720p', '16:9') => '1280x720',
        ('720p', '9:16') => '720x1280',
        ('1080p', '16:9') => '1792x1024',
        ('1080p', '9:16') => '1024x1792',
        _ => throw const VideoException(
          VideoErrorCode.invalid_request,
          field: 'resolution',
        ),
      };

  /// Agnes 方言：mode/aspect_ratio 显式声明，size 是分辨率档位，参考媒体按
  /// 角色分组为平铺帧字段与 images/audios/videos 数组，全部发送公开 URL。
  Map<String, dynamic> _encodeAgnes(
    VideoRequest request,
    List<VideoReference> references,
  ) {
    return {
      'model': request.modelId,
      'prompt': request.prompt,
      'seconds': '${request.durationSeconds}',
      'size': request.resolution,
      'aspect_ratio': request.ratio,
      'mode': switch (request.mode) {
        VideoMode.text => 'text',
        VideoMode.first_frame ||
        VideoMode.first_last_frame => 'keyframe',
        VideoMode.reference => 'reference',
      },
      for (final ref in references)
        if (ref.role == VideoInputRole.first_frame ||
            ref.role == VideoInputRole.last_frame)
          ref.role.name: ref.url.toString(),
      for (final (role, key) in [
        (VideoInputRole.reference_image, 'images'),
        (VideoInputRole.reference_audio, 'audios'),
        (VideoInputRole.reference_video, 'videos'),
      ])
        if (references.any((ref) => ref.role == role))
          key: [
            for (final ref in references.where((ref) => ref.role == role))
              if (role == VideoInputRole.reference_video)
                {'url': ref.url.toString()}
              else
                ref.url.toString(),
          ],
    };
  }

  @override
  String submissionId(Map<String, dynamic> json) => _taskId(json);

  /// 轮询响应里的 ID 必须与提交回执同规则，否则 /content 回退会拼出另一个
  /// 任务 ID（agnes-hub-go 的响应同时含自有 job_id 与上游 id）。
  String _taskId(Map<String, dynamic> json) {
    // 取舍依据各网关轮询路由：agnes-hub-go 只认自有 job_id（创建响应同时
    // 透传上游 task_id，取错则 JobByID 404）；直连 Agnes 只有 task_id，且
    // /v1/videos/{id} 只认 task_xxx——video_id 打过去返回 400
    // task_not_exist，因此绝不回退到 video_id；官方方言只有 id。
    final id =
        (json['job_id'] ?? json['task_id'] ?? json['id']) as String?;
    if (id == null || id.trim().isEmpty) {
      throw const FormatException('Missing task ID');
    }
    return id;
  }

  @override
  Future<http.StreamedResponse> download(
    http.Client transport,
    Uri url,
    VideoSubmission task,
  ) async {
    // 官方 /content 端点带凭据才可取片；Agnes 与网关返回的成片 URL 是公开
    // 地址，绝不能把账号 key 发给第三方。
    final content = this.url(
      'videos/${Uri.encodeComponent(task.taskId)}/content',
    );
    if (url != content) {
      return transport.send(http.Request('GET', url));
    }
    // url() 已校验 endpoint 与 apiKey；仅第一跳附带凭据，重定向到对象存储
    // 后不再继承账号 key。
    var target = content;
    for (var redirects = 0; redirects <= 5; redirects++) {
      final request = http.Request('GET', target)..followRedirects = false;
      if (redirects == 0) {
        request.headers['Authorization'] = 'Bearer $apiKey';
      }
      final response = await transport.send(request);
      if (!{301, 302, 303, 307, 308}.contains(response.statusCode)) {
        return response;
      }
      final location = response.headers['location'];
      await response.stream.drain<void>();
      if (location == null) {
        break;
      }
      target = target.resolve(location);
      // 与 new_api / openrouter 一致：重定向目标必须是 https，防止成片
      // 被明文重定向篡改或窃听。
      if (target.scheme != 'https' ||
          target.host.isEmpty ||
          target.userInfo.isNotEmpty) {
        break;
      }
    }
    throw const VideoException(VideoErrorCode.invalid_response);
  }

  @override
  VideoTaskResult decodeResult(Map<String, dynamic> json) {
    final status = json['status'] as String;
    // 官方方言 completed 后经鉴权 /content 取片；Agnes 直接给顶层 url。
    // metadata.url 只作旧网关回退，非法占位符一律回退到 /content。
    final videoUrl = status == 'completed'
        ? _firstUrl(json) ??
              url('videos/${Uri.encodeComponent(_taskId(json))}/content')
        : null;
    return videoResult(
      switch (status) {
        'in_progress' => 'running',
        // videoResult 只认 succeeded；上游 completed 不换算会永远停在 unknown。
        'completed' => 'succeeded',
        _ => status,
      },
      videoUrl?.toString(),
    );
  }

  Uri? _absoluteUrl(Object? value) {
    if (value is! String || value.trim().isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri;
  }

  Uri? _firstUrl(Map<String, dynamic> json) {
    for (final key in ['url', 'video_url']) {
      final uri = _absoluteUrl(json[key]);
      if (uri != null) {
        return uri;
      }
    }
    final metadata = json['metadata'];
    if (metadata is Map) {
      return _absoluteUrl(metadata['url']);
    }
    return null;
  }
}
