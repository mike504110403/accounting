/// 新手互動導覽（Mike 裁示 2026-09-03 第二版）：
/// 全畫面遮罩 disable，只有「高亮的目標」可以點；互動步點下去會真的導到指定分頁
/// （點『預算』tab → 進預算頁 → 高亮摘要卡說明……），路線走完才結束。
/// 換頁由 router 監聽自動前進；說明步按「下一步」。除了指定路徑，其餘一律點不到。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart' show routerProvider;
import 'theme_mode.dart' show sharedPrefsProvider;

// ── 目標 key 註冊表 ──────────────────────────────────────────────────────
// 各頁面在自己的 widget 上掛 `tutorialKey('名字')`；overlay 用同名查 Rect。
final _keys = <String, GlobalKey>{};
GlobalKey tutorialKey(String name) => _keys.putIfAbsent(name, GlobalKey.new);

// ── 步驟 ────────────────────────────────────────────────────────────────
class TutorialStep {
  const TutorialStep({
    required this.title,
    required this.body,
    this.target,
    this.maxHoleHeight,
    this.advanceRoutePrefix,
    this.advanceOnTap = false,
    this.popModalOnNext = false,
  });

  final String title;
  final String body;

  /// `tutorialKey` 的名字；null＝置中卡片、不聚焦。
  final String? target;

  /// 目標太高（如整個列表）時鏤空的高度上限。
  final double? maxHoleHeight;

  /// 互動步：亮區可點、其餘全鎖；路由走到這個前綴就自動前進。
  final String? advanceRoutePrefix;

  /// 互動步（不換路由版）：點亮區就前進（點擊照常放行給真的 UI，如開 bottom sheet）。
  final bool advanceOnTap;

  /// 按「下一步」離開本步時先把最上層 modal（bottom sheet）收掉。
  final bool popModalOnNext;

  bool get interactive => advanceRoutePrefix != null || advanceOnTap;
}

const tutorialSteps = <TutorialStep>[
  TutorialStep(
    target: 'fab-add',
    title: '記帳入口',
    body: '之後點「＋新增」記收入或支出：一步一步選分類、填金額就好。先看看其他頁面。',
  ),
  TutorialStep(
    target: 'tab-budget',
    advanceRoutePrefix: '/budget',
    title: '點「預算」',
    body: '點亮起的「預算」分頁，看看本月預算長什麼樣。',
  ),
  TutorialStep(
    target: 'budget-summary',
    title: '本月預算',
    body: '設定各分類的本月預算；所有共同支出都會扣，超支一眼看得到。',
  ),
  TutorialStep(
    target: 'tab-lists',
    advanceRoutePrefix: '/lists',
    title: '點「清單」',
    body: '再點「清單」分頁。',
  ),
  TutorialStep(
    target: 'lists-fab',
    advanceOnTap: true,
    title: '試試新增購物項目',
    body: '點亮起的「＋」，看看新增購物項目長什麼樣。',
  ),
  TutorialStep(
    popModalOnNext: true,
    title: '購物清單',
    body: '就是這個小精靈：名稱→店家→預估→分類→負責人。買完在清單勾選結帳，自動變成一筆支出。先關掉它繼續。',
  ),
  TutorialStep(
    target: 'tab-entries',
    advanceRoutePrefix: '/entries',
    title: '回「帳目」',
    body: '點「帳目」回到主頁。',
  ),
  TutorialStep(
    target: 'view-toggle',
    title: '家庭與個人',
    body: '家庭視角看共同帳（共同錢包與預算）；個人視角看自己的份額與私人帳。代墊先動個人餘額，結算簽核完成就歸位。',
  ),
  TutorialStep(
    target: 'settings-gear',
    advanceRoutePrefix: '/settings',
    title: '點齒輪',
    body: '設定都在齒輪裡，點進去看看。',
  ),
  TutorialStep(
    target: 'settings-categories',
    advanceRoutePrefix: '/settings/categories',
    title: '點「分類管理」',
    body: '點亮起的「分類管理」進去看看。',
  ),
  TutorialStep(
    title: '分類管理',
    body: '這裡可以新增分類、拖曳排序；左滑任一列＝編輯／刪除。分攤比例、餘額設定與清帳也都在設定裡。',
  ),
  TutorialStep(
    title: '準備好了！',
    body: '兩個人共用一本帳：對方用邀請碼加入後，記的每一筆都會即時同步。開始記帳吧。',
  ),
];

// ── 控制器 ──────────────────────────────────────────────────────────────
class TutorialController extends Notifier<int?> {
  static const doneKey = 'tutorialDone';

  @override
  int? build() {
    TutorialNavObserver.onModalPushed = advanceFromTap;
    ref.onDispose(() {
      if (TutorialNavObserver.onModalPushed == advanceFromTap) {
        TutorialNavObserver.onModalPushed = null;
      }
    });
    return null;
  }

  /// 首次進帳目頁時呼叫：沒看過才開。widget test 的 binding 不是
  /// [WidgetsFlutterBinding]，不自動開（測試用 [start] 顯式驅動）。
  void maybeStart() {
    if (state != null) return;
    if (WidgetsBinding.instance is! WidgetsFlutterBinding) return;
    final prefs = ref.read(sharedPrefsProvider);
    if (prefs?.getBool(doneKey) ?? false) return;
    state = 0;
  }

  void start() => state = 0;

  /// 亮區被「作用」了（真點擊的 pointer up／modal 打開）：目前是 advanceOnTap 步才前進。
  /// 兩條偵測路徑都會呼叫；第一次前進後步驟已換，第二次自然 no-op。
  void advanceFromTap() {
    final s = state;
    if (s == null || !tutorialSteps[s].advanceOnTap) return;
    next();
  }

  void next() {
    final s = state;
    if (s == null) return;
    if (tutorialSteps[s].popModalOnNext) {
      // 收掉互動步開出來的 bottom sheet（root navigator 最上層 modal）。
      // 先推進步驟、pop 排 post-frame：web 上帶焦點的 sheet 在 pop 當下會炸
      // didChangeViewFocus（2026-09-03 e2e 實測），同步 pop 會把推進截斷。
      FocusManager.instance.primaryFocus?.unfocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(routerProvider).routerDelegate.navigatorKey.currentState?.maybePop();
      });
    }
    if (s >= tutorialSteps.length - 1) {
      finish();
    } else {
      state = s + 1;
    }
  }

  /// 互動步：路由走到指定前綴就前進。
  void onRouteChanged(String location) {
    final s = state;
    if (s == null) return;
    final prefix = tutorialSteps[s].advanceRoutePrefix;
    if (prefix != null && location.startsWith(prefix)) next();
  }

  void finish() {
    state = null;
    ref.read(sharedPrefsProvider)?.setBool(doneKey, true);
    // 導覽在設定頁收尾：結束一律帶回帳目頁。
    final router = ref.read(routerProvider);
    final config = router.routerDelegate.currentConfiguration;
    final location = config.isEmpty ? '' : config.last.matchedLocation;
    if (!location.startsWith('/entries')) router.go('/entries');
  }
}

final tutorialProvider = NotifierProvider<TutorialController, int?>(TutorialController.new);

/// root navigator 的觀察者（router.dart 掛進 GoRouter.observers）：
/// advanceOnTap 步靠「modal 真的開了」前進——語意點擊（無障礙／e2e）不產生
/// pointer event，光靠全域 pointer route 會漏（2026-09-03 e2e 實測）。
final tutorialNavObserver = TutorialNavObserver();

class TutorialNavObserver extends NavigatorObserver {
  static void Function()? onModalPushed;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) onModalPushed?.call();
  }
}

// ── Overlay 圖層（掛在 MaterialApp.builder 的 Stack 最上層）────────────────
class TutorialLayer extends ConsumerStatefulWidget {
  const TutorialLayer({super.key});

  @override
  ConsumerState<TutorialLayer> createState() => _TutorialLayerState();
}

class _TutorialLayerState extends ConsumerState<TutorialLayer> {
  RouterDelegate<Object>? _delegate;
  bool _retryScheduled = false;

  /// build 時快取：全域 pointer route 用（advanceOnTap 步）。
  Rect? _activeHole;
  bool _advanceOnTap = false;

  @override
  void initState() {
    super.initState();
    // 互動步靠路由變化前進：監聽 go_router 的 delegate。
    final router = ref.read(routerProvider);
    _delegate = router.routerDelegate;
    _delegate!.addListener(_onRoute);
    // advanceOnTap 步：用全域 pointer route 觀察（不參與 hit test、不吃事件），
    // 點在亮區內就前進——點擊照常放行給真的 UI（例如開 bottom sheet）。
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    _delegate?.removeListener(_onRoute);
    super.dispose();
  }

  void _onPointer(PointerEvent e) {
    if (e is! PointerUpEvent) return;
    final hole = _activeHole;
    if (!_advanceOnTap || hole == null) return;
    if (!hole.inflate(6).contains(e.position)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(tutorialProvider.notifier).advanceFromTap();
    });
  }

  void _onRoute() {
    final router = ref.read(routerProvider);
    // push 疊上去的頁（如 /settings）不會反映在 currentConfiguration.uri，
    // 要看最上層 match 的 matchedLocation（2026-09-03 實測）。
    final config = router.routerDelegate.currentConfiguration;
    final location = config.isEmpty ? '' : config.last.matchedLocation;
    ref.read(tutorialProvider.notifier).onRouteChanged(location);
    if (mounted) setState(() {}); // 換頁後目標 rect 要重算
  }

  Rect? _rectOf(String name, {double? maxHeight}) {
    final ctx = _keys[name]?.currentContext;
    final box = ctx?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    var rect = box.localToGlobal(Offset.zero) & box.size;
    if (maxHeight != null && rect.height > maxHeight) {
      rect = rect.topLeft & Size(rect.width, maxHeight);
    }
    return rect;
  }

  @override
  Widget build(BuildContext context) {
    final stepIndex = ref.watch(tutorialProvider);
    if (stepIndex == null) return const SizedBox.shrink();
    final step = tutorialSteps[stepIndex];
    final hole = step.target == null ? null : _rectOf(step.target!, maxHeight: step.maxHoleHeight);

    // 剛換頁那一幀目標可能還沒 layout：排一次重試，拿得到 rect 再畫洞。
    if (step.target != null && hole == null && !_retryScheduled) {
      _retryScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _retryScheduled = false;
        if (mounted) setState(() {});
      });
    }

    _activeHole = hole;
    _advanceOnTap = step.advanceOnTap;

    final t = Theme.of(context);
    final screen = MediaQuery.of(context).size;
    final last = stepIndex == tutorialSteps.length - 1;

    // ExcludeFocus＋逐步換 key：web 上（semantics 開啟時）點卡片按鈕會觸發 view-focus
    // 轉移，撞到上一步卡片殘留的 Focus 元素直接炸（2026-09-03 e2e 實測）；
    // 卡片不需要鍵盤焦點，整包排除＋每步全新子樹最乾淨。
    final card = ExcludeFocus(
      child: KeyedSubtree(
      key: ValueKey('tutorial-step-view-$stepIndex'),
      child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Material(
        key: const Key('tutorial-card'),
        color: t.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(step.title, style: t.textTheme.titleMedium)),
                  Text('${stepIndex + 1}/${tutorialSteps.length}',
                      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                ],
              ),
              const SizedBox(height: 8),
              Text(step.body, style: t.textTheme.bodyMedium),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (step.interactive) ...[
                    Icon(Icons.touch_app_outlined, size: 16, color: t.colorScheme.primary),
                    const SizedBox(width: 4),
                    Text('點亮起的地方繼續',
                        style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.primary)),
                  ],
                  const Spacer(),
                  if (!last)
                    TextButton(
                      key: const Key('tutorial-skip'),
                      onPressed: () => ref.read(tutorialProvider.notifier).finish(),
                      child: const Text('跳過'),
                    ),
                  if (!step.interactive) ...[
                    const SizedBox(width: 4),
                    FilledButton(
                      key: const Key('tutorial-next'),
                      onPressed: () => ref.read(tutorialProvider.notifier).next(),
                      child: Text(last ? '開始使用' : '下一步'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
      ),
      ),
    );

    // 卡片放洞的另一側；沒有洞就置中。
    Widget positionedCard;
    if (hole == null) {
      positionedCard = Center(child: Padding(padding: const EdgeInsets.all(24), child: card));
    } else if (hole.center.dy < screen.height / 2) {
      positionedCard = Positioned(
        top: hole.bottom + 16,
        left: 24,
        right: 24,
        child: Align(alignment: Alignment.topCenter, child: card),
      );
    } else {
      positionedCard = Positioned(
        bottom: screen.height - hole.top + 16,
        left: 24,
        right: 24,
        child: Align(alignment: Alignment.bottomCenter, child: card),
      );
    }

    final blockHole = !step.interactive || hole == null;
    final inflated = hole?.inflate(6);
    return Stack(
      children: [
        // 遮罩只畫不擋（點擊阻擋交給下面的 blocker，互動步才留得出洞）。
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _BarrierPainter(
                hole: hole,
                // 互動步的目標加光暈高亮（Mike 裁示 2026-09-03）。
                glow: step.interactive ? t.colorScheme.primary : null,
              ),
            ),
          ),
        ),
        if (blockHole)
          Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () {}))
        else ...[
          // 互動步：洞以外四塊全擋，洞內放行給真的 UI（點下去會導頁）。
          Positioned(left: 0, top: 0, right: 0, height: inflated!.top,
              child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () {})),
          Positioned(left: 0, top: inflated.bottom, right: 0, bottom: 0,
              child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () {})),
          Positioned(left: 0, top: inflated.top, width: inflated.left, height: inflated.height,
              child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () {})),
          Positioned(left: inflated.right, top: inflated.top, right: 0, height: inflated.height,
              child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () {})),
        ],
        positionedCard,
      ],
    );
  }
}

class _BarrierPainter extends CustomPainter {
  const _BarrierPainter({this.hole, this.glow});
  final Rect? hole;

  /// 互動步的高亮色；null＝說明步（細白描邊即可）。
  final Color? glow;

  @override
  void paint(Canvas canvas, Size size) {
    var path = Path()..addRect(Offset.zero & size);
    final h = hole;
    if (h != null) {
      path = Path.combine(
        PathOperation.difference,
        path,
        Path()..addRRect(RRect.fromRectAndRadius(h.inflate(6), const Radius.circular(14))),
      );
    }
    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: 0.62));
    if (h != null) {
      final rrect = RRect.fromRectAndRadius(h.inflate(6), const Radius.circular(14));
      final g = glow;
      if (g != null) {
        // 光暈（外圈模糊）＋主題色粗描邊：被選中的按鈕清楚亮起。
        canvas.drawRRect(
          rrect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 10
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8)
            ..color = g.withValues(alpha: 0.9),
        );
        canvas.drawRRect(
          rrect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = g,
        );
      } else {
        canvas.drawRRect(
          rrect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Colors.white.withValues(alpha: 0.85),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_BarrierPainter old) => old.hole != hole || old.glow != glow;
}
