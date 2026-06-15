import 'package:flutter/material.dart';
import 'db_helper.dart';

class TransactionHistoryPage extends StatefulWidget {
  const TransactionHistoryPage({super.key});

  @override
  State<TransactionHistoryPage> createState() => _TransactionHistoryPageState();
}

class _TransactionHistoryPageState extends State<TransactionHistoryPage> {
  final GlobalKey<RefreshIndicatorState> _refreshKey =
      GlobalKey<RefreshIndicatorState>();

  bool _showDailyItemTotals = false;
  DateTime? _selectedFilterDate;
  String? _selectedFilterDateText;
  Future<void> _pickFilterDate() async {
    final DateTime now = DateTime.now();

    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedFilterDate ?? now,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      helpText: 'Select transaction date',
    );

    if (picked == null) return;

    final String formatted =
        "${picked.year.toString().padLeft(4, '0')}-"
        "${picked.month.toString().padLeft(2, '0')}-"
        "${picked.day.toString().padLeft(2, '0')}";

    setState(() {
      _selectedFilterDate = picked;
      _selectedFilterDateText = formatted;
    });
  }

  void _clearFilterDate() {
    setState(() {
      _selectedFilterDate = null;
      _selectedFilterDateText = null;
    });
  }

  String _extractDateKey(String rawDateStr) {
    if (rawDateStr.length >= 10) {
      return rawDateStr.substring(0, 10);
    }
    return '';
  }

  Map<String, Map<String, int>> _buildDailyItemTotals(
    List<Map<String, dynamic>> historyLogs,
  ) {
    final Map<String, Map<String, int>> result = {};

    for (final sale in historyLogs) {
      final String rawDateStr = sale['saleDate']?.toString() ?? '';
      final String dateKey = rawDateStr.length >= 10
          ? rawDateStr.substring(0, 10)
          : 'Unknown Date';

      final String typeText = sale['type']?.toString() ?? '';
      final List<String> parts = typeText.split(',');

      result.putIfAbsent(dateKey, () => {});

      for (final rawPart in parts) {
        final String part = rawPart.trim();

        final match = RegExp(r'^(\d+)x\s+(.+)$').firstMatch(part);
        if (match != null) {
          final int qty = int.tryParse(match.group(1) ?? '0') ?? 0;
          final String itemName = match.group(2)?.trim() ?? 'Unknown Item';

          result[dateKey]![itemName] = (result[dateKey]![itemName] ?? 0) + qty;
        }
      }
    }

    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F6F6),
      appBar: AppBar(
        title: const Text("Transaction History"),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.amber,
        actions: [
          IconButton(
            tooltip: "Search by date",
            onPressed: _pickFilterDate,
            icon: const Icon(Icons.search),
          ),
          if (_selectedFilterDateText != null)
            IconButton(
              tooltip: "Clear date filter",
              onPressed: _clearFilterDate,
              icon: const Icon(Icons.close),
            ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _showDailyItemTotals
                                ? "📦 Daily Item Totals"
                                : "📜 Full Archive Sorted by Day",
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: Colors.grey,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    "Item Totals",
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey,
                    ),
                  ),
                  Switch(
                    value: _showDailyItemTotals,
                    onChanged: (value) {
                      setState(() {
                        _showDailyItemTotals = value;
                      });
                    },
                  ),
                ],
              ),
              if (_selectedFilterDateText != null) ...[
                const SizedBox(height: 6),
                Text(
                  "Filtered date: $_selectedFilterDateText",
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.deepOrange,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Expanded(
                child: RefreshIndicator(
                  key: _refreshKey,
                  onRefresh: () async {
                    setState(() {});
                  },
                  child: FutureBuilder<List<Map<String, dynamic>>>(
                    future: DBHelper.getSales(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }

                      if (!snapshot.hasData || snapshot.data!.isEmpty) {
                        return ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            SizedBox(height: 100),
                            Center(
                              child: Text(
                                "No transaction history records discovered yet.",
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.grey),
                              ),
                            ),
                          ],
                        );
                      }

                      final List<Map<String, dynamic>> allHistoryLogs =
                          snapshot.data!;

                      final List<Map<String, dynamic>> historyLogs =
                          _selectedFilterDateText == null
                          ? allHistoryLogs
                          : allHistoryLogs.where((sale) {
                              final String rawDateStr =
                                  sale['saleDate']?.toString() ?? '';
                              return _extractDateKey(rawDateStr) ==
                                  _selectedFilterDateText;
                            }).toList();

                      if (historyLogs.isEmpty) {
                        return ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            const SizedBox(height: 100),
                            Center(
                              child: Text(
                                _selectedFilterDateText == null
                                    ? "No transaction history records discovered yet."
                                    : "No transactions found on $_selectedFilterDateText",
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.grey),
                              ),
                            ),
                          ],
                        );
                      }

                      final dailyItemTotals = _buildDailyItemTotals(
                        historyLogs,
                      );

                      final Map<String, List<Map<String, dynamic>>>
                      groupedLogs = {};

                      for (final sale in historyLogs) {
                        final String rawDateStr =
                            sale['saleDate']?.toString() ?? '';
                        final String dateKey = rawDateStr.length >= 10
                            ? rawDateStr.substring(0, 10)
                            : "Unknown Date";

                        groupedLogs.putIfAbsent(dateKey, () => []);
                        groupedLogs[dateKey]!.add(sale);
                      }

                      if (_showDailyItemTotals) {
                        final List<String> sortedDates =
                            dailyItemTotals.keys.toList()
                              ..sort((a, b) => b.compareTo(a));

                        return ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: sortedDates.length,
                          itemBuilder: (context, dateIndex) {
                            final String dateHeader = sortedDates[dateIndex];
                            final Map<String, int> itemTotals =
                                dailyItemTotals[dateHeader] ?? {};

                            final List<MapEntry<String, int>> entries =
                                itemTotals.entries.toList()
                                  ..sort((a, b) => b.value.compareTo(a.value));

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 8.0,
                                    horizontal: 4.0,
                                  ),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.orange.shade100,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      "📅 $dateHeader",
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.orange.shade900,
                                      ),
                                    ),
                                  ),
                                ),
                                ...entries.map((entry) {
                                  return Card(
                                    color: Colors.white,
                                    elevation: 0.5,
                                    margin: const EdgeInsets.only(bottom: 6),
                                    child: ListTile(
                                      dense: true,
                                      leading: const Icon(
                                        Icons.inventory_2,
                                        color: Colors.orange,
                                      ),
                                      title: Text(
                                        entry.key,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      trailing: Text(
                                        "${entry.value} pcs",
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: Colors.deepOrange,
                                        ),
                                      ),
                                    ),
                                  );
                                }),
                              ],
                            );
                          },
                        );
                      }

                      final List<String> sortedDates = groupedLogs.keys.toList()
                        ..sort((a, b) => b.compareTo(a));

                      return ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: sortedDates.length,
                        itemBuilder: (context, dateIndex) {
                          final String dateHeader = sortedDates[dateIndex];
                          final List<Map<String, dynamic>> dailySales =
                              groupedLogs[dateHeader]!;

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8.0,
                                  horizontal: 4.0,
                                ),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade300,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    "📅 $dateHeader",
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.grey.shade800,
                                    ),
                                  ),
                                ),
                              ),
                              ...dailySales.map((saleRecord) {
                                final String rawSaleDate =
                                    saleRecord['saleDate']?.toString() ?? '';
                                final String timeDisplay =
                                    rawSaleDate.length >= 16
                                    ? rawSaleDate.substring(11, 16)
                                    : "00:00";

                                final double price =
                                    (saleRecord['price'] as num?)?.toDouble() ??
                                    0.0;

                                return Card(
                                  color: Colors.white,
                                  elevation: 0.5,
                                  margin: const EdgeInsets.only(bottom: 6),
                                  child: ListTile(
                                    dense: true,
                                    leading: const Icon(
                                      Icons.receipt_long,
                                      color: Colors.green,
                                    ),
                                    title: Text(
                                      "${saleRecord['type']}",
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    subtitle: Text(
                                      "Time: $timeDisplay",
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          "${price.toStringAsFixed(0)} MMK",
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color: Colors.green,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        IconButton(
                                          icon: const Icon(
                                            Icons.delete_outline,
                                            color: Colors.red,
                                            size: 18,
                                          ),
                                          onPressed: () async {
                                            await DBHelper.deleteSale(
                                              saleRecord['id'],
                                            );
                                            setState(() {});
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }),
                            ],
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
