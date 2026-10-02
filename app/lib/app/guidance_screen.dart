/// 접근성 안내 화면. 화면 전체가 큰 버튼(탭 → 시작/정지 토글).
/// 상태별 고대비 색·초대형 글자·아이콘(A안) + 스크린리더 Semantics.
///
/// 전맹 사용자에겐 엔진 음성/햅틱이 이미 전달된다. 이 시각 표시는 저시력·도우미용,
/// Semantics 라벨은 전맹 사용자의 화면 조작(시작/정지 확인)용.
///
/// [GuidanceScreen.debug](기본 kClipDebug)일 때만 하단에 진단 스트립(카메라
/// 프리뷰+ROI 사각형, API/카메라 상태 한 줄)을 겹쳐 그린다 — 시연 영상에서
/// "이중 판정"을 보이고 실기기에서 카메라가 왜 안 되는지 보기 위한 것이다.
/// 스크린리더에는 노출하지 않고(ExcludeSemantics) 탭도 통과시켜(IgnorePointer)
/// 큰 버튼의 탭 영역·Semantics는 그대로다. 기본 빌드에서는 위젯 트리가 같다.
library;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../camera/camera_vision_source.dart';
import '../signals/judge.dart';
import '../signals/signal_reading.dart';
import 'config.dart';
import 'guidance_controller.dart';
import 'demo_signal.dart';

/// 진단 스트립이 차지할 수 있는 최대 높이(화면 높이 비율).
const double _kDebugStripMaxFrac = 0.35;

class GuidanceScreen extends StatefulWidget {
  final GuidanceController controller;
  final bool disposeController;

  /// 진단 스트립 표시. 기본은 빌드 플래그(kClipDebug) — 배포 빌드에서는 false.
  final bool debug;

  /// [disposeController]는 이 화면이 컨트롤러를 만든 route일 때만 true로 둔다.
  /// 테스트나 상위 위젯이 주입한 컨트롤러의 기존 소유권은 기본값(false)으로 유지한다.
  const GuidanceScreen({
    super.key,
    required this.controller,
    this.disposeController = false,
    this.debug = kClipDebug,
  });

  @override
  State<GuidanceScreen> createState() => _GuidanceScreenState();
}

class _GuidanceScreenState extends State<GuidanceScreen>
    with WidgetsBindingObserver {
  GuidanceController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 화면이 실제로 가려져 영상 근거가 사라지는 paused/hidden/detached에서만
    // 정지한다(정지 음성 포함 — 전맹 사용자가 멈춘 것을 알 수 있게). 복귀 후에는
    // 사용자가 카메라를 다시 조준하고 명시적으로 시작해야 한다.
    //
    // inactive는 유지한다: 카메라 권한 다이얼로그·알림창·제어센터·전화 수신 직전
    // 같은 잠깐의 포커스 이탈이며, 여기서 정지하면 첫 탭이 띄우는 권한 요청만으로
    // 안내가 취소된다. 그 사이 카메라 프레임이 끊기면 판독이 stale→unknown이
    // 되어 judge가 wait로 수렴하므로 안전 정책은 그대로다.
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        if (controller.running) controller.stop();
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.disposeController) controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final v = _view(controller);
        final button = GestureDetector(
          onTap: controller.toggle,
          behavior: HitTestBehavior.opaque,
          // 버튼(탭 동작 + 상태 요약)과 상태 라이브 리전을 형제 노드로 분리.
          // 버튼 쪽 Semantics는 excludeSemantics로 내부 Text들의 개별 낭독을
          // 막아 라벨 하나로만 읽히게 하되, 상태 텍스트는 별도의
          // liveRegion 노드로 두어 excludeSemantics에 가려지지 않게 한다
          // (spec §4.3: 상태 전환 시 스크린리더가 재포커스 없이 자동 낭독).
          child: Semantics(
            key: const Key('guidanceButtonSemantics'),
            button: true,
            container: true,
            label: v.semanticLabel,
            child: Container(
              color: v.bg,
              width: double.infinity,
              height: double.infinity,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (controller.lastApiReading?.raw == kDemoSignalRaw)
                    Container(
                      key: const Key('demoSignalBanner'),
                      margin: const EdgeInsets.only(bottom: 24),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      color: const Color(0xFFFFD60A),
                      child: const Text(
                        '시연 데이터 · 실제 신호 아님',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: Colors.black,
                        ),
                      ),
                    ),
                  Semantics(
                    excludeSemantics: true,
                    child: v.icon != null
                        ? Text(v.icon!, style: const TextStyle(fontSize: 96))
                        : const SizedBox.shrink(),
                  ),
                  const SizedBox(height: 16),
                  Semantics(
                    key: const Key('guidanceLiveRegionSemantics'),
                    liveRegion: true,
                    container: true,
                    label: v.liveLabel,
                    excludeSemantics: true,
                    child: Column(
                      children: [
                        Text(
                          v.title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 56,
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                          ),
                        ),
                        if (v.sub != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            v.sub!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        if (!widget.debug) return Scaffold(body: button);
        // 진단 스트립은 큰 버튼 "위"에 겹친다(버튼 자체는 위와 동일한 트리).
        return Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              button,
              _DebugStrip(controller: controller),
            ],
          ),
        );
      },
    );
  }
}

/// 진단 스트립 한 줄(순수 함수, 화면 테스트와 같은 포맷). 예:
/// "API 초록 12.3s · 카메라 초록 2.4% streaming · 31ms · 신선 120ms".
/// 값이 없으면 '—'. 카메라가 NONE인 이유(too_dark 등)가 있으면 이유와 밝기를
/// 뒤에 붙여 "왜 안 잡히는지"를 실기기에서 바로 볼 수 있게 한다.
String diagnosticsLine({
  SignalReading? api,
  SignalReading? vision,
  VisionSourceStatus? status,
  VisionDiagnostics? diagnostics,
}) {
  const dash = '—';
  final apiRemain = api?.remainSec;
  final apiPart = api == null
      ? 'API $dash'
      : 'API ${_colorName(api.color)} '
            '${apiRemain == null ? dash : '${apiRemain.toStringAsFixed(1)}s'}';
  final area = diagnostics?.areaRatio;
  final cameraPart =
      '카메라 ${vision == null ? dash : _colorName(vision.color)} '
      '${area == null ? dash : '${(area * 100).toStringAsFixed(1)}%'} '
      '${status?.name ?? dash}';
  final processPart = diagnostics == null ? dash : '${diagnostics.processMs}ms';
  final age = diagnostics?.lastFrameAgeMs;
  final freshPart = '신선 ${age == null ? dash : '${age}ms'}';

  final line = StringBuffer(
    '$apiPart · $cameraPart · $processPart · $freshPart',
  );
  final reason = diagnostics?.lastReason ?? '';
  if (reason.isNotEmpty) {
    line.write(' · $reason');
    final brightness = diagnostics?.brightness;
    if (brightness != null) line.write(' · 밝기 ${brightness.round()}');
  }
  return line.toString();
}

String _colorName(SignalColor color) => switch (color) {
  SignalColor.green => '초록',
  SignalColor.red => '빨강',
  SignalColor.clearance => '점멸',
  SignalColor.unknown => '없음',
};

/// 화면 하단 진단 스트립(디버그 빌드 전용). 프리뷰(있을 때만)+ROI 사각형 위에
/// 상태 한 줄. 스크린리더 제외·탭 통과 — 전맹 사용자용 큰 버튼은 그대로다.
class _DebugStrip extends StatelessWidget {
  final GuidanceController controller;

  const _DebugStrip({required this.controller});

  @override
  Widget build(BuildContext context) {
    final preview = controller.visionPreviewController;
    final line = diagnosticsLine(
      api: controller.lastApiReading,
      vision: controller.lastVisionReading,
      status: controller.visionStatus,
      diagnostics: controller.visionDiagnostics,
    );
    final maxHeight = MediaQuery.sizeOf(context).height * _kDebugStripMaxFrac;
    return ExcludeSemantics(
      child: IgnorePointer(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            key: const Key('debugStrip'),
            width: double.infinity,
            constraints: BoxConstraints(maxHeight: maxHeight),
            color: const Color(0xCC000000),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 스트리밍 중에만 non-null. 폐기된 컨트롤러는 절대 그리지 않는다.
                if (preview != null && preview.value.isInitialized)
                  Flexible(
                    child: CameraPreview(preview, child: const _RoiOverlay()),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  child: Text(
                    line,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 프리뷰 위에 검출 ROI(중앙 kRoiFrac 비율)를 얇은 테두리로 겹친다.
/// CameraPreview의 child는 프리뷰와 같은 AspectRatio 박스를 꽉 채우므로 비율
/// 좌표가 프레임 좌표와 일치한다(frame_converter의 중앙 crop과 같은 비율).
class _RoiOverlay extends StatelessWidget {
  const _RoiOverlay();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FractionallySizedBox(
        widthFactor: kRoiFrac,
        heightFactor: kRoiFrac,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFFFEB3B), width: 1.5),
          ),
        ),
      ),
    );
  }
}

class _View {
  final Color bg;
  final String? icon;
  final String title;
  final String? sub;
  final String liveLabel;
  final String semanticLabel;
  _View(
    this.bg,
    this.icon,
    this.title,
    this.sub,
    this.liveLabel,
    this.semanticLabel,
  );
}

_View _view(GuidanceController c) {
  const tapStart = ' 두 번 탭하면 안내를 시작합니다.';
  const tapStop = ' 두 번 탭하면 안내를 정지합니다.';
  // 정지 화면은 running뿐 아니라 "아직 판정 없음"(decision==unknown)일 때도
  // 보인다. GuidanceController.tickOnce()는 running을 바꾸지 않고 decision만
  // 갱신하므로(테스트가 start() 없이 tickOnce()만으로 상태를 주입), running
  // 하나만으로는 "판정이 나온 정지 전 상태"를 구분할 수 없다. decision이
  // unknown이 아니면(walk/wait 판정이 있으면) running 여부와 무관하게 그
  // 판정을 그대로 보여준다.
  if (!c.running && c.decision == Decision.unknown) {
    if (!c.apiConfigured) {
      const liveLabel = '설정 오류. T-Data API 키가 없습니다. API 키를 넣어 다시 실행하세요.';
      return _View(
        const Color(0xFF5A5A5A),
        '⚙️',
        '설정 필요',
        'T-Data API 키가 없습니다',
        liveLabel,
        liveLabel,
      );
    }
    // liveLabel(상태만)과 semanticLabel(상태+조작 안내)이 같은 문구 조각을
    // 공유 — 아래서 tapStart/tapStop을 붙여 semanticLabel을 만든다(DRY).
    const liveLabel = '정지됨. 뒤 카메라를 보행 신호등으로 향하세요.';
    return _View(
      const Color(0xFF222222),
      null,
      '화면을 눌러\n안내를 시작하세요',
      '카메라를 신호등 중앙으로',
      liveLabel,
      '$liveLabel$tapStart',
    );
  }
  switch (c.decision) {
    case Decision.walk:
      final sub = c.remainSec != null ? '${c.remainSec!.round()}초' : null;
      final liveLabel = '건너세요.${sub != null ? " $sub 남음." : ""}';
      return _View(
        const Color(0xFF0A8F3C),
        '🚶',
        '건너세요',
        sub,
        liveLabel,
        '$liveLabel$tapStop',
      );
    case Decision.wait:
      final reason = decisionReasonText(c.reason);
      final liveLabel = '기다리세요. $reason.';
      return _View(
        const Color(0xFFC31414),
        '✋',
        '기다리세요',
        reason,
        liveLabel,
        '$liveLabel$tapStop',
      );
    case Decision.unknown:
      final reason = decisionReasonText(c.reason);
      final liveLabel = '$reason. 대기하세요.';
      return _View(
        const Color(0xFF5A5A5A),
        '❓',
        '확인 불가',
        reason,
        liveLabel,
        '$liveLabel$tapStop',
      );
  }
}
