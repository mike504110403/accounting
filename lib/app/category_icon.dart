import 'package:flutter/material.dart';

/// Category.icon（字串）→ IconData。未知名稱回 category 圖示。
IconData categoryIcon(String name) => _map[name] ?? Icons.category_outlined;

const _map = <String, IconData>{
  'restaurant': Icons.restaurant,
  'local_dining': Icons.local_dining,
  'inventory_2': Icons.inventory_2_outlined,
  'home': Icons.home_outlined,
  'bolt': Icons.bolt,
  'directions_car': Icons.directions_car_outlined,
  'sports_esports': Icons.sports_esports_outlined,
  'payments': Icons.payments_outlined,
  'card_giftcard': Icons.card_giftcard,
  'shopping_bag': Icons.shopping_bag_outlined,
  'local_hospital': Icons.local_hospital_outlined,
  'school': Icons.school_outlined,
  'pets': Icons.pets,
  'flight': Icons.flight_outlined,
  'phone_iphone': Icons.phone_iphone,
  'checkroom': Icons.checkroom,
  'child_care': Icons.child_care,
  'savings': Icons.savings_outlined,
  'more_horiz': Icons.more_horiz,
};

/// 分類管理可選的圖示清單。
List<String> get categoryIconNames => _map.keys.toList();
