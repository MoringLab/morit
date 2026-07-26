import 'package:flutter_test/flutter_test.dart';
import 'package:morit/morit/media/download_backend.dart';

void main() {
  final client = DownloadBackendClient(
    endpoint: Uri.parse('https://downloads.example.com'),
    accessToken: () => 'test-token',
  );

  test('queued jobs do not require a final file URL', () {
    final job = client.jobFromJson({
      'id': 'job-1',
      'status': 'queued',
      'stage': 'queued',
      'progress': 0,
      'transfer_url':
          'https://downloads.example.com/v1/transfers/job-1?ticket=opaque',
      'file': null,
    });

    expect(job.ready, isFalse);
    expect(job.fileUrl, isNull);
    expect(job.transferUrl?.host, 'downloads.example.com');
  });

  test('cross-origin transfer and file URLs are rejected', () {
    expect(
      () => client.jobFromJson({
        'id': 'job-1',
        'status': 'complete',
        'transfer_url': 'https://evil.example/transfer',
        'file': {
          'url': 'https://downloads.example.com/v1/files/job-1',
          'file_name': 'video.mp4',
          'mime_type': 'video/mp4',
          'kind': 'video',
        },
      }),
      throwsA(isA<DownloadBackendException>()),
    );
  });

  test('engine failures keep the public log id for support', () {
    final job = client.jobFromJson({
      'id': 'job-1',
      'status': 'failed',
      'error': {
        'code': 'ENGINE_FAILED',
        'message': '다운로드 엔진이 처리하지 못했습니다.',
        'engine': 'yt-dlp',
        'platform': 'instagram',
        'log_id': 'abc123',
        'causes': [
          {
            'code': 'ENGINE_FAILED',
            'engine': 'cobalt',
            'log_id': 'fallback456',
          },
        ],
      },
    });

    expect(job.error?.displayMessage, contains('log:abc123'));
    expect(job.error?.displayMessage, contains('log:fallback456'));
  });

  test('unknown or zero file sizes stay unknown instead of becoming 0B', () {
    final job = client.jobFromJson({
      'id': 'job-1',
      'status': 'complete',
      'file': {
        'url': 'https://downloads.example.com/v1/files/job-1',
        'file_name': 'video.mp4',
        'mime_type': 'video/mp4',
        'kind': 'video',
        'content_length': 0,
      },
    });

    expect(job.contentLength, isNull);
  });
}
