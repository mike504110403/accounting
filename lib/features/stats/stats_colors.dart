/// 圖表配色：一律由 `Theme.of(context).colorScheme` 派生，不硬寫顏色，深淺色都可讀。
library;

import 'package:flutter/material.dart';

/// 色相步進用黃金角。分類數量沒有上限（設定頁可無限新增），等距步進（如 47°）
/// 會在圈數整除時撞色——47×8 = 376 ≈ 16°，第 1 與第 9 塊幾乎同色。
/// 黃金角的無理數性質保證任意前 n 個色相都盡量散開，不存在「第幾塊開始撞」。
const _hueStepDegrees = 137.508;

/// 飽和度／明度基準：暗色主題要更亮更淡才讀得出來，亮色主題反之。
const _sliceSaturationDark = 0.52;
const _sliceSaturationLight = 0.58;
const _sliceLightnessDark = 0.62;
const _sliceLightnessLight = 0.44;

/// 相鄰塊再加一點飽和度／明度差，避免只靠色相分辨（對色盲也友善些）。
///
/// 黃金角已經把色相拉得夠開，這裡的步進只是次要線索，所以比等距步進時代收小：
/// 步進太大會把暗色主題的塊推到過亮（0.62 + 0.07 起跳就開始發白）。
/// 收成 0.05 後，暗色落在 0.62–0.67、亮色落在 0.44–0.49，兩邊都在可讀帶內。
const _saturationStep = 0.05;
const _lightnessStep = 0.05;
const _saturationCycle = 3;
const _lightnessCycle = 2;

/// 圓餅第 [i] 塊的顏色：以主色色相為基準按黃金角轉，明度依亮／暗主題選一組。
Color sliceColor(ColorScheme cs, int i) {
  final base = HSLColor.fromColor(cs.primary);
  final dark = cs.brightness == Brightness.dark;
  final hue = (base.hue + i * _hueStepDegrees) % 360.0;
  final sat = (dark ? _sliceSaturationDark : _sliceSaturationLight) -
      (i % _saturationCycle) * _saturationStep;
  final light = (dark ? _sliceLightnessDark : _sliceLightnessLight) +
      (i % _lightnessCycle) * _lightnessStep;
  return HSLColor.fromAHSL(1, hue, sat.clamp(0.15, 0.95), light.clamp(0.15, 0.85)).toColor();
}

/// 依索引取色；索引 < 0 代表「找不到對應的分類／成員」，用中性灰，
/// 不要退回 0——那會和第一個分類同色，看起來像是同一項。
Color sliceColorAt(ColorScheme cs, int i) => i < 0 ? cs.outline : sliceColor(cs, i);

/// 四條趨勢線的顏色，各取主題語意色。
Color spendColor(ColorScheme cs) => cs.primary;
Color budgetColor(ColorScheme cs) => cs.tertiary;
Color overColor(ColorScheme cs) => cs.error;
Color balanceColor(ColorScheme cs) => cs.secondary;
