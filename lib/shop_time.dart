
class ShopTime {

  static const Duration offset = Duration(hours: 6, minutes: 30);

  static const int sqlOffsetMinutes = 390;

  static const String sqlLocalDate = '''
    substr(
      CASE WHEN saleDate LIKE '%Z'
           THEN COALESCE(datetime(saleDate, '+$sqlOffsetMinutes minutes'), saleDate)
           ELSE saleDate
      END, 1, 10)
  ''';

  /// Same, for item_history's createdAt column.
  static const String sqlLocalDateCreatedAt = '''
    substr(
      CASE WHEN createdAt LIKE '%Z'
           THEN COALESCE(datetime(createdAt, '+$sqlOffsetMinutes minutes'), createdAt)
           ELSE createdAt
      END, 1, 10)
  ''';

  /// Converts a stored timestamp to shop-local time.
  /// Returns null if the value is missing or unparseable.
  static DateTime? parse(dynamic rawValue) {
    final String raw = rawValue?.toString().trim() ?? '';
    if (raw.isEmpty) return null;

    try {
      final DateTime parsed = DateTime.parse(raw);

      // Does the string carry a timezone? "...Z" or "...+06:30"
      final bool hasZone =
          raw.endsWith('Z') || RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(raw);

      if (!hasZone) {
        // Legacy row — already written in shop-local time. Leave it.
        return parsed;
      }

      return parsed.toUtc().add(offset);
    } catch (_) {
      return null;
    }
  }

  /// "14:05" in shop time.
  static String timeOf(dynamic rawValue) {
    final DateTime? dt = parse(rawValue);
    if (dt == null) return "--:--";

    final String hour = dt.hour.toString().padLeft(2, '0');
    final String minute = dt.minute.toString().padLeft(2, '0');
    return "$hour:$minute";
  }

  /// "2026-08-07" in shop time. Use as the grouping key.
  static String dateOf(dynamic rawValue) {
    final DateTime? dt = parse(rawValue);
    if (dt == null) return "Unknown Date";

    final String y = dt.year.toString().padLeft(4, '0');
    final String m = dt.month.toString().padLeft(2, '0');
    final String d = dt.day.toString().padLeft(2, '0');
    return "$y-$m-$d";
  }

  /// "2026-08-07 14:05" — for anywhere you want both.
  static String dateTimeOf(dynamic rawValue) {
    final DateTime? dt = parse(rawValue);
    if (dt == null) return "Unknown";
    return "${dateOf(rawValue)} ${timeOf(rawValue)}";
  }

  /// Today's date key in shop time. Use this rather than
  /// DateTime.now() when defaulting a date filter — near midnight the
  /// device's idea of "today" can differ from the shop's.
  static String todayKey() =>
      dateOf(DateTime.now().toUtc().toIso8601String());
}