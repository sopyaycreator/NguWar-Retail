import 'package:flutter/material.dart';
import 'package:nguwar/shop_time.dart';
import 'db_helper.dart';


/// Displays the stock ledger.
///
/// Each row is a movement with a SIGNED delta: negative means stock left the
/// shelf, positive means it arrived. `qty` holds the same number unsigned, so
/// older screens keep working — direction lives in `delta`.
class ItemHistoryPage extends StatefulWidget {
  const ItemHistoryPage({super.key});


  @override
  State<ItemHistoryPage> createState() => _ItemHistoryPageState();
}


/// How a movement should be drawn, derived from its action and direction.
class _MovementStyle {
  final IconData icon;
  final Color color;
  final String label;


  const _MovementStyle(this.icon, this.color, this.label);
}


class _ItemHistoryPageState extends State<ItemHistoryPage> {
  final GlobalKey<RefreshIndicatorState> _refreshKey =
      GlobalKey<RefreshIndicatorState>();


  final ScrollController _scrollController = ScrollController();


  final List<Map<String, dynamic>> _historyLogs = [];


  // Load 10 distinct dates at a time, not 20 raw history rows.
  static const int _pageSize = 10;


  int _offset = 0;
  bool _isInitialLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;


  @override
  void initState() {
    super.initState();


    _loadFirstPage();


    _scrollController.addListener(() {
      if (!_scrollController.hasClients) return;


      if (_scrollController.position.pixels >=
          _scrollController.position.maxScrollExtent - 200) {
        _loadMore();
      }
    });
  }


  Future<List<Map<String, dynamic>>> _loadLogsForDates(
    List<String> dateKeys,
  ) async {
    final List<Map<String, dynamic>> logs = [];

    for (final dateKey in dateKeys) {
      final dailyLogs = await DBHelper.getItemHistoryByDate(dateKey);
      logs.addAll(dailyLogs);
    }

    return logs;
  }


  Future<void> _loadFirstPage() async {
    setState(() {
      _isInitialLoading = true;
      _isLoadingMore = false;
      _hasMore = true;
      _offset = 0;
      _historyLogs.clear();
    });


    final List<String> firstDates =
        await DBHelper.getItemHistoryDatesPaginated(
      limit: _pageSize,
      offset: 0,
    );
    final List<Map<String, dynamic>> firstPage =
        await _loadLogsForDates(firstDates);


    if (!mounted) return;


    setState(() {
      _historyLogs.addAll(firstPage);
      _offset = firstDates.length;
      _hasMore = firstDates.length == _pageSize;
      _isInitialLoading = false;
    });
  }


  Future<void> _loadMore() async {
    if (_isInitialLoading || _isLoadingMore || !_hasMore) return;


    setState(() {
      _isLoadingMore = true;
    });


    final List<String> nextDates =
        await DBHelper.getItemHistoryDatesPaginated(
      limit: _pageSize,
      offset: _offset,
    );
    final List<Map<String, dynamic>> nextPage =
        await _loadLogsForDates(nextDates);


    if (!mounted) return;


    setState(() {
      _historyLogs.addAll(nextPage);
      _offset += nextDates.length;
      _hasMore = nextDates.length == _pageSize;
      _isLoadingMore = false;
    });
  }

Map<String, List<Map<String, dynamic>>> _groupLogsByDate() {
  final Map<String, List<Map<String, dynamic>>> groupedLogs = {};

  for (final log in _historyLogs) {
    final String action =
        (log['action']?.toString() ?? '').trim().toLowerCase();

    // UI only: hide Sold/Sale records.
    // All other records—including Added Item, Edited Item,
    // Updated Item, Return, Deleted Item, Stock Take—remain visible.
    if (action == 'sale' || action == 'sold') {
      continue;
    }

    final String dateKey = ShopTime.dateOf(log['createdAt']);

    groupedLogs.putIfAbsent(dateKey, () => []);
    groupedLogs[dateKey]!.add(log);
  }

  return groupedLogs;
}
  /// Resolves a row's signed delta.
  ///
  /// Rows written before the migration have delta = 0 and only an action, so
  /// they are interpreted the same way the server does. 'Edited Item' stays
  /// at 0 on purpose: its old `qty` was an absolute total, not a change, and
  /// showing it as ±qty would be a lie.
  int _resolveDelta(Map<String, dynamic> log) {
    final int stored = (log['delta'] as num?)?.toInt() ?? 0;
    if (stored != 0) return stored;


    final int qty = ((log['qty'] as num?)?.toInt() ?? 0).abs();
    final String action = (log['action']?.toString() ?? '').toLowerCase();


    if (action == 'added item' || action == 'updated item') return qty;
    if (action == 'deleted item') return -qty;
    if (action.contains('sale') || action.contains('sold')) return -qty;
    if (action.contains('return') || action.contains('void')) return qty;


    return 0; // 'Edited Item' and anything unrecognised
  }


  _MovementStyle _styleFor(String action, int delta) {
    switch (action.toLowerCase()) {
      case 'sale':
        return const _MovementStyle(
          Icons.point_of_sale_rounded,
          Colors.red,
          'Sold',
        );
      case 'return':
        return const _MovementStyle(Icons.undo_rounded, Colors.teal, 'Returned');
      case 'added item':
        return const _MovementStyle(
          Icons.add_box_rounded,
          Colors.green,
          'New item',
        );
      case 'updated item':
        return const _MovementStyle(
          Icons.inventory_rounded,
          Colors.green,
          'Stock in',
        );
      case 'deleted item':
        return const _MovementStyle(
          Icons.delete_rounded,
          Colors.grey,
          'Removed',
        );
      case 'stock take':
        return const _MovementStyle(
          Icons.fact_check_rounded,
          Colors.deepPurple,
          'Counted',
        );
      case 'edited item':
        if (delta > 0) {
          return const _MovementStyle(
            Icons.edit_note_rounded,
            Colors.green,
            'Adjusted up',
          );
        }
        if (delta < 0) {
          return const _MovementStyle(
            Icons.edit_note_rounded,
            Colors.orange,
            'Adjusted down',
          );
        }
        return const _MovementStyle(
          Icons.edit_rounded,
          Colors.blueGrey,
          'Details edited',
        );
      default:
        if (delta > 0) {
          return const _MovementStyle(
            Icons.arrow_downward_rounded,
            Colors.green,
            'Stock in',
          );
        }
        if (delta < 0) {
          return const _MovementStyle(
            Icons.arrow_upward_rounded,
            Colors.red,
            'Stock out',
          );
        }
        return const _MovementStyle(Icons.info_outline, Colors.grey, '');
    }
  }


String _timeOf(String rawCreatedAt) => ShopTime.timeOf(rawCreatedAt);


  Widget _buildMovementTile(Map<String, dynamic> logRecord) {
    final String action = logRecord['action']?.toString() ?? 'Unknown';
    final String itemName = logRecord['itemName']?.toString() ?? 'Unknown Item';
    final String barcode = logRecord['barcode']?.toString() ?? '-';
    final String device = logRecord['deviceId']?.toString() ?? '';


    final int delta = _resolveDelta(logRecord);
    final _MovementStyle style = _styleFor(action, delta);
    final String timeDisplay = _timeOf(logRecord['createdAt']?.toString() ?? '');


    // Minus sign, not a hyphen — reads clearly at small sizes.
    final String deltaText = delta > 0
        ? "+$delta"
        : delta < 0
            ? "\u2212${delta.abs()}"
            : "—";


    return Card(
      color: Colors.white,
      elevation: 0.5,
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        dense: true,
        leading: CircleAvatar(
          radius: 18,
          backgroundColor: style.color.withOpacity(0.12),
          child: Icon(style.icon, color: style.color, size: 20),
        ),
        title: Text(
          itemName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          "${style.label.isEmpty ? action : style.label} • $timeDisplay\n"
          "ID: $barcode${device.isEmpty ? '' : ' • $device'}",
          style: const TextStyle(fontSize: 11),
        ),
        isThreeLine: true,
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              deltaText,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: delta == 0 ? Colors.grey : style.color,
              ),
            ),
            if (delta != 0)
              Text(
                "pcs",
                style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
              ),
          ],
        ),
      ),
    );
  }


  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    final Map<String, List<Map<String, dynamic>>> groupedLogs = _groupLogsByDate();


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


                          // Net movement for the day — the number that should
                          // reconcile against a physical count.
                          final int dayNet = dailyLogs.fold<int>(
                            0,
                            (sum, log) => sum + _resolveDelta(log),
                          );


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
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        "📅 $dateHeader",
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.orange.shade900,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Text(
                                        "Net: ${dayNet > 0 ? '+' : ''}$dayNet",
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: dayNet < 0
                                              ? Colors.red.shade800
                                              : Colors.green.shade800,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              ...dailyLogs.map(_buildMovementTile),
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