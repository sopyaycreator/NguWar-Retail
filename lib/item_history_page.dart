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

  final ScrollController _scrollController = ScrollController();

  final List<Map<String, dynamic>> _historyLogs = [];

  static const int _pageSize = 20;

  int _offset = 0;
  bool _isInitialLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();

    _loadFirstPage();

    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
          _scrollController.position.maxScrollExtent - 200) {
        _loadMore();
      }
    });
  }

  Future<void> _loadFirstPage() async {
    setState(() {
      _isInitialLoading = true;
      _isLoadingMore = false;
      _hasMore = true;
      _offset = 0;
      _historyLogs.clear();
    });

    final List<Map<String, dynamic>> firstPage =
        await DBHelper.getItemHistoryPaginated(limit: _pageSize, offset: 0);

    if (!mounted) return;

    setState(() {
      _historyLogs.addAll(firstPage);
      _offset = firstPage.length;
      _hasMore = firstPage.length == _pageSize;
      _isInitialLoading = false;
    });
  }

  Future<void> _loadMore() async {
    if (_isInitialLoading || _isLoadingMore || !_hasMore) return;

    setState(() {
      _isLoadingMore = true;
    });

    final List<Map<String, dynamic>> nextPage =
        await DBHelper.getItemHistoryPaginated(
          limit: _pageSize,
          offset: _offset,
        );

    if (!mounted) return;

    setState(() {
      _historyLogs.addAll(nextPage);
      _offset += nextPage.length;
      _hasMore = nextPage.length == _pageSize;
      _isLoadingMore = false;
    });
  }

  Map<String, List<Map<String, dynamic>>> _groupLogsByDate() {
    final Map<String, List<Map<String, dynamic>>> groupedLogs = {};

    for (final log in _historyLogs) {
      final String rawDateStr = log['createdAt']?.toString() ?? '';
      final String dateKey = rawDateStr.length >= 10
          ? rawDateStr.substring(0, 10)
          : "Unknown Date";

      groupedLogs.putIfAbsent(dateKey, () => []);
      groupedLogs[dateKey]!.add(log);
    }

    return groupedLogs;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, List<Map<String, dynamic>>> groupedLogs =
        _groupLogsByDate();

    final List<String> sortedDates = groupedLogs.keys.toList()
      ..sort((a, b) => b.compareTo(a));

    return Scaffold(
      backgroundColor: const Color(0xFFF6F6F6),
      appBar: AppBar(
        title: const Text("Item History"),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.amber,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: RefreshIndicator(
            key: _refreshKey,
            onRefresh: _loadFirstPage,
            child: _isInitialLoading
                ? const Center(child: CircularProgressIndicator())
                : _historyLogs.isEmpty
                ? ListView(
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
                  )
                : ListView.builder(
                    controller: _scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: sortedDates.length + 1,
                    itemBuilder: (context, dateIndex) {
                      if (dateIndex == sortedDates.length) {
                        if (_isLoadingMore) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 16),
                            child: Center(child: CircularProgressIndicator()),
                          );
                        }

                        if (!_hasMore) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 16),
                            child: Center(
                              child: Text(
                                "No more records.",
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                            ),
                          );
                        }

                        return const SizedBox(height: 16);
                      }

                      final String dateHeader = sortedDates[dateIndex];
                      final List<Map<String, dynamic>> dailyLogs =
                          groupedLogs[dateHeader]!;

                      dailyLogs.sort((a, b) {
                        final String aDate = a['createdAt']?.toString() ?? '';
                        final String bDate = b['createdAt']?.toString() ?? '';
                        return bDate.compareTo(aDate);
                      });

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
                            String timeDisplay = "00:00";

                            if (rawCreatedAt.isNotEmpty) {
                              try {
                                // 1. Parse the string to a DateTime object
                                // 2. Convert it to the phone's local timezone
                                DateTime localTime = DateTime.parse(
                                  rawCreatedAt,
                                ).toLocal();

                                // 3. Format it manually to HH:mm (or use intl package's DateFormat)
                                String hour = localTime.hour.toString().padLeft(
                                  2,
                                  '0',
                                );
                                String minute = localTime.minute
                                    .toString()
                                    .padLeft(2, '0');
                                timeDisplay = "$hour:$minute";
                              } catch (e) {
                                // Fallback just in case the string format is invalid
                                timeDisplay = rawCreatedAt.length >= 16
                                    ? rawCreatedAt.substring(11, 16)
                                    : "00:00";
                              }
                            }

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
                  ),
          ),
        ),
      ),
    );
  }
}
