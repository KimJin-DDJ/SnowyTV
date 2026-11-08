import 'package:flutter/material.dart';

/// 电视遥控器用的屏幕键盘：字母 + 数字网格，方向键移动、确认键输入。
///
/// 配合拼音首字母检索使用，比如输入 `dpcq` 就能找到「斗破苍穹」。
/// 所有按键等宽等高排成网格，Flutter 默认的方向键遍历就能准确上下左右移动。
class TvSearchKeyboard extends StatelessWidget {
  const TvSearchKeyboard({
    super.key,
    required this.onInput,
    required this.onBackspace,
    required this.onClear,
    required this.onSubmit,
    this.onSystemKeyboard,
    this.firstKeyFocus,
    this.keySize = 40,
  });

  final ValueChanged<String> onInput;
  final VoidCallback onBackspace;
  final VoidCallback onClear;
  final VoidCallback onSubmit;

  /// 切到系统输入法（输入中文）。
  final VoidCallback? onSystemKeyboard;
  final FocusNode? firstKeyFocus;
  final double keySize;

  static const _columns = 6;
  static const _chars = 'abcdefghijklmnopqrstuvwxyz1234567890';
  static const _gap = 6.0;

  double get width => keySize * _columns + _gap * (_columns - 1);

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var start = 0; start < _chars.length; start += _columns) {
      final end = (start + _columns).clamp(0, _chars.length);
      rows.add(Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = start; i < end; i++) ...[
            if (i > start) const SizedBox(width: _gap),
            _Key(
              label: _chars[i].toUpperCase(),
              width: keySize,
              height: keySize,
              focusNode: i == 0 ? firstKeyFocus : null,
              onPressed: () => onInput(_chars[i]),
            ),
          ],
        ],
      ));
    }
    final third = (width - _gap * 2) / 3;
    final half = (width - _gap) / 2;
    rows.add(Row(mainAxisSize: MainAxisSize.min, children: [
      _Key(
          icon: Icons.space_bar_rounded,
          label: '空格',
          width: third,
          height: keySize,
          onPressed: () => onInput(' ')),
      const SizedBox(width: _gap),
      _Key(
          icon: Icons.backspace_outlined,
          label: '删除',
          width: third,
          height: keySize,
          onPressed: onBackspace),
      const SizedBox(width: _gap),
      _Key(
          icon: Icons.clear_all_rounded,
          label: '清空',
          width: third,
          height: keySize,
          onPressed: onClear),
    ]));
    rows.add(Row(mainAxisSize: MainAxisSize.min, children: [
      _Key(
          icon: Icons.search_rounded,
          label: '搜索',
          width: onSystemKeyboard == null ? width : half,
          height: keySize,
          primary: true,
          onPressed: onSubmit),
      if (onSystemKeyboard != null) ...[
        const SizedBox(width: _gap),
        _Key(
            icon: Icons.translate_rounded,
            label: '中文输入',
            width: half,
            height: keySize,
            onPressed: onSystemKeyboard!),
      ],
    ]));

    return FocusTraversalGroup(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: _gap),
            rows[i],
          ],
        ],
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({
    required this.label,
    required this.width,
    required this.height,
    required this.onPressed,
    this.icon,
    this.focusNode,
    this.primary = false,
  });

  final String label;
  final IconData? icon;
  final double width;
  final double height;
  final VoidCallback onPressed;
  final FocusNode? focusNode;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final style = ButtonStyle(
      padding: const WidgetStatePropertyAll(EdgeInsets.zero),
      minimumSize: WidgetStatePropertyAll(Size(width, height)),
      fixedSize: WidgetStatePropertyAll(Size(width, height)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12)))),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.focused)) return colors.primary;
        return primary ? colors.primaryContainer : colors.surfaceContainerHigh;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.focused)) return colors.onPrimary;
        return primary ? colors.onPrimaryContainer : colors.onSurface;
      }),
      textStyle: WidgetStatePropertyAll(
          TextStyle(fontSize: icon == null ? 18 : 14, fontWeight: FontWeight.w600)),
    );
    final child = icon == null
        ? Text(label)
        : Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 18),
            const SizedBox(width: 4),
            Text(label),
          ]);
    return FilledButton(
      focusNode: focusNode,
      style: style,
      onPressed: onPressed,
      child: child,
    );
  }
}
