import 'package:flutter/material.dart';
import 'db_helper.dart';

class ItemHistoryPage extends StatefulWidget {
  const ItemHistoryPage({super.key});

  @override
  State<ItemHistoryPage> createState() => _ItemHistoryPageState();
}

class _ItemHistoryPageState extends State<ItemHistoryPage> {
  final GlobalKey<RefreshIndicatorState> _refreshKey =
      GlobalKey<RefreshIndicatorState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F6F6),
      appBar: AppBar(
        title: const Text("Item History"),
        centerTitle: true,
        elevation: 0,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: RefreshIndicator(
            key: _refreshKey,
            onRefresh: () async {
              setState(() {});
            },
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: DBHelper.getAllItemHistory(),
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
                          "No item history records discovered yet.",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    ],
                  );
                }

                final historyLogs = snapshot.data!;

                final Map<String, List<Map<String, dynamic>>> groupedLogs = {};

                for (final log in historyLogs) {
                  final String rawDateStr = log['createdAt']?.toString() ?? '';
                  final String dateKey = rawDateStr.length >= 10
                      ? rawDateStr.substring(0, 10)
                      : "Unknown Date";

                  groupedLogs.putIfAbsent(dateKey, () => []);
                  groupedLogs[dateKey]!.add(log);
                }

                final List<String> sortedDates = groupedLogs.keys.toList()
                  ..sort((a, b) => b.compareTo(a));

                return ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: sortedDates.length,
                  itemBuilder: (context, dateIndex) {
                    final String dateHeader = sortedDates[dateIndex];
                    final List<Map<String, dynamic>> dailyLogs =
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
                              color: Colors.amber.shade100,
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
                        ...dailyLogs.map((logRecord) {
                          final String rawCreatedAt =
                              logRecord['createdAt']?.toString() ?? '';
                          final String timeDisplay = rawCreatedAt.length >= 16
                              ? rawCreatedAt.substring(11, 16)
                              : "00:00";

                          final String action =
                              logRecord['action']?.toString() ?? 'Unknown';
                          final String itemName =
                              logRecord['itemName']?.toString() ??
                                  'Unknown Item';
                          final String barcode =
                              logRecord['barcode']?.toString() ?? '-';
                          final int qty =
                              (logRecord['qty'] as num?)?.toInt() ?? 0;

                          return Card(
                            color: Colors.white,
                            elevation: 0.5,
                            margin: const EdgeInsets.only(bottom: 6),
                            child: ListTile(
                              dense: true,
                              leading: Icon(
                                action == 'Added Item'
                                    ? Icons.add_box_rounded
                                    : Icons.edit_note_rounded,
                                color: action == 'Added Item'
                                    ? Colors.green
                                    : Colors.blue,
                              ),
                              title: Text(
                                "$action - $itemName",
                                style: const TextStyle(
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              subtitle: Text(
                                "Barcode: $barcode\nQty: $qty | Time: $timeDisplay",
                                style: const TextStyle(fontSize: 11),
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
      ),
    );
  }
}