import 'package:flutter/material.dart';

/// 收入色：淺色主題用深綠、深色主題用亮綠，兩種主題都可讀。
Color incomeColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? const Color(0xFF7CD992) : const Color(0xFF2E7D32);
