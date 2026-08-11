import 'package:flutter/material.dart';
import 'db_helper.dart';

import 'shop_time.dart';

/// One occurrence of an item being sold — a single receipt containing it.
class _SoldOccurrence {
  final String saleDate;
  final int qty;
  final double receiptTotal;
  final String receiptText;

  const _SoldOccurrence({
    required this.saleDate,
    required this.qty,
    required this.receiptTotal,
    required this.receiptText,
  });
}

class TransactionHistoryPage extends StatefulWidget {
  final bool isUnlocked;

  const TransactionHistoryPage({super.key, required this.isUnlocked});

  @override
  State<TransactionHistoryPage> createState() => _TransactionHistoryPageState();
}

class _TransactionHistoryPageState extends State<TransactionHistoryPage> {
  final GlobalKey<RefreshIndicatorState> _refreshKey =
      GlobalKey<RefreshIndicatorState>();

  final ScrollController _scrollController = ScrollController();
  final TextEditingController _soldItemSearchController =
      TextEditingController();

  static const int _datePageSize = 3;

  /// Matches "2x Sunkist Orange" in the receipt's `type` string.
  static final RegExp _lineItemPattern = RegExp(r'^(\d+)x\s+(.+)$');

  final List<Map<String, dynamic>> _dateSummaries = [];
  final Map<String, List<Map<String, dynamic>>> _salesByDate = {};

  bool _showDailyItemTotals = false;
  bool _isInitialLoading = true;
  bool _isLoadingMore = false;
  bool _hasMoreData = true;

  int _dateOffset = 0;

  DateTime? _selectedFilterDate;
  String? _selectedFilterDateText;

  String _soldItemSearchText = '';

  @override
  void initState() {
    super.initState();

    _loadInitialSales();

    _scrollController.addListener(() {
      if (!_scrollController.hasClients) return;

      if (_scrollController.position.pixels >=
          _scrollController.position.maxScrollExtent - 200) {
        _loadMoreSales();
      }
    });
  }

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0.0;
  }

  // =========================================================================
  // DATA
  // =========================================================================

  Future<void> _loadInitialSales() async {
    setState(() {
      _isInitialLoading = true;
      _isLoadingMore = false;
      _hasMoreData = true;
      _dateOffset = 0;
      _dateSummaries.clear();
      _salesByDate.clear();
    });

    try {
      if (_selectedFilterDateText != null) {
        final summary =
            await DBHelper.getSaleDateSummary(_selectedFilterDateText!);

        if (summary == null) {
          if (!mounted) return;
          setState(() {
            _hasMoreData = false;
            _isInitialLoading = false;
          });
          return;
        }

        final sales = await DBHelper.getSalesByDate(_selectedFilterDateText!);

        if (!mounted) return;

        setState(() {
          _dateSummaries.add(summary);
          _salesByDate[_selectedFilterDateText!] = sales;
          _hasMoreData = false;
          _isInitialLoading = false;
        });

        return;
      }

      final summaries = await DBHelper.getSaleDateSummariesPaginated(
        limit: _datePageSize,
        offset: _dateOffset,
      );

      final Map<String, List<Map<String, dynamic>>> loadedSales = {};

      for (final summary in summaries) {
        final String dateKey = summary['dateKey']?.toString() ?? '';
        if (dateKey.isEmpty) continue;
        loadedSales[dateKey] = await DBHelper.getSalesByDate(dateKey);
      }

      if (!mounted) return;

      setState(() {
        _dateSummaries.addAll(summaries);
        _salesByDate.addAll(loadedSales);
        _dateOffset += summaries.length;
        _hasMoreData = summaries.length == _datePageSize;
        _isInitialLoading = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isInitialLoading = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Failed to load transactions: $e")),
      );
    }
  }

  Future<void> _loadMoreSales() async {
    if (_isLoadingMore || !_hasMoreData || _isInitialLoading) return;
    if (_selectedFilterDateText != null) return;

    setState(() {
      _isLoadingMore = true;
    });

    try {
      final summaries = await DBHelper.getSaleDateSummariesPaginated(
        limit: _datePageSize,
        offset: _dateOffset,
      );

      final Map<String, List<Map<String, dynamic>>> loadedSales = {};

      for (final summary in summaries) {
        final String dateKey = summary['dateKey']?.toString() ?? '';
        if (dateKey.isEmpty) continue;
        loadedSales[dateKey] = await DBHelper.getSalesByDate(dateKey);
      }

      if (!mounted) return;

      setState(() {
        _dateSummaries.addAll(summaries);
        _salesByDate.addAll(loadedSales);
        _dateOffset += summaries.length;
        _hasMoreData = summaries.length == _datePageSize;
        _isLoadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isLoadingMore = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Failed to load more transactions: $e")),
      );
    }
  }

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

    final String formatted = "${picked.year.toString().padLeft(4, '0')}-"
        "${picked.month.toString().padLeft(2, '0')}-"
        "${picked.day.toString().padLeft(2, '0')}";

    setState(() {
      _selectedFilterDate = picked;
      _selectedFilterDateText = formatted;
    });

    await _loadInitialSales();
  }

  Future<void> _clearFilterDate() async {
    setState(() {
      _selectedFilterDate = null;
      _selectedFilterDateText = null;
    });

    await _loadInitialSales();
  }

  void _clearSoldItemSearch() {
    setState(() {
      _soldItemSearchText = '';
      _soldItemSearchController.clear();
    });
  }

  // =========================================================================
  // RECEIPT PARSING
  //
  // `sales.type` is a display string: "2x Sunkist Orange, 1x Lays".
  // It's the only per-item record a sale carries, so both the daily totals
  // and the drill-down below are parsed back out of it.
  //
  // LIMITATION: an item name containing a comma will split wrongly. If that
  // ever becomes a real problem, the fix is a `sale_lines` table rather than
  // a smarter regex.
  // =========================================================================

  Map<String, int> _buildItemTotalsForSales(
    List<Map<String, dynamic>> dailySales,
  ) {
    final Map<String, int> result = {};

    for (final sale in dailySales) {
      final String typeText = sale['type']?.toString() ?? '';

      for (final rawPart in typeText.split(',')) {
        final match = _lineItemPattern.firstMatch(rawPart.trim());
        if (match == null) continue;

        final int qty = int.tryParse(match.group(1) ?? '0') ?? 0;
        final String itemName = match.group(2)?.trim() ?? 'Unknown Item';

        result[itemName] = (result[itemName] ?? 0) + qty;
      }
    }

    return result;
  }

  /// Every receipt from [dailySales] that contains [itemName], oldest first.
  List<_SoldOccurrence> _occurrencesOf(
    List<Map<String, dynamic>> dailySales,
    String itemName,
  ) {
    final List<_SoldOccurrence> occurrences = [];

    for (final sale in dailySales) {
      final String typeText = sale['type']?.toString() ?? '';
      int qtyInThisSale = 0;

      for (final rawPart in typeText.split(',')) {
        final match = _lineItemPattern.firstMatch(rawPart.trim());
        if (match == null) continue;

        if ((match.group(2)?.trim() ?? '') == itemName) {
          qtyInThisSale += int.tryParse(match.group(1) ?? '0') ?? 0;
        }
      }

      if (qtyInThisSale > 0) {
        occurrences.add(_SoldOccurrence(
          saleDate: sale['saleDate']?.toString() ?? '',
          qty: qtyInThisSale,
          receiptTotal: _toDouble(sale['price']),
          receiptText: typeText,
        ));
      }
    }

    // Chronological — the sheet reads as a timeline through the day.
    occurrences.sort((a, b) => a.saleDate.compareTo(b.saleDate));
    return occurrences;
  }

  List<MapEntry<String, int>> _filterSoldItemEntries(
    Map<String, int> itemTotals,
  ) {
    final String keyword = _soldItemSearchText.trim().toLowerCase();

    final List<MapEntry<String, int>> entries = itemTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    if (keyword.isEmpty) return entries;

    return entries
        .where((entry) => entry.key.toLowerCase().contains(keyword))
        .toList();
  }

  // =========================================================================
  // ITEM DRILL-DOWN SHEET
  // =========================================================================

  void _showSoldItemDetail({
    required String itemName,
    required String dateHeader,
    required List<Map<String, dynamic>> dailySales,
  }) {
    final List<_SoldOccurrence> occurrences =
        _occurrencesOf(dailySales, itemName);

    final int totalPcs =
        occurrences.fold<int>(0, (sum, o) => sum + o.qty);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.35,
          maxChildSize: 0.92,
          expand: false,
          builder: (context, scrollController) {
            return Container(
              decoration: const BoxDecoration(
                color: Color(0xFFF6F6F6),
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Column(
                children: [
                  // Drag handle
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 10),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade400,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),

                  _buildSheetHeader(
                    itemName: itemName,
                    dateHeader: dateHeader,
                    totalPcs: totalPcs,
                    receiptCount: occurrences.length,
                  ),

                  const SizedBox(height: 4),

                  Expanded(
                    child: occurrences.isEmpty
                        ? const Center(
                            child: Text(
                              "No sales found for this item.",
                              style: TextStyle(color: Colors.grey),
                            ),
                          )
                        : ListView.builder(
                            controller: scrollController,
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                            itemCount: occurrences.length,
                            itemBuilder: (context, index) {
                              return _buildOccurrenceTile(
                                occurrences[index],
                                index + 1,
                                itemName,
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSheetHeader({
    required String itemName,
    required String dateHeader,
    required int totalPcs,
    required int receiptCount,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.amber.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.inventory_2_rounded,
                  color: Colors.amber.shade900,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      itemName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "📅 $dateHeader",
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),

          Row(
            children: [
              Expanded(
                child: _buildStatChip(
                  label: "Total sold",
                  value: "$totalPcs pcs",
                  color: Colors.deepOrange,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildStatChip(
                  label: receiptCount == 1 ? "Receipt" : "Receipts",
                  value: "$receiptCount",
                  color: Colors.green.shade700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatChip({
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOccurrenceTile(
    _SoldOccurrence occurrence,
    int sequence,
    String itemName,
  ) {
    final String time = ShopTime.timeOf(occurrence.saleDate);

    // The rest of the receipt, so you can see what it sold alongside.
    final String others = occurrence.receiptText
        .split(',')
        .map((p) => p.trim())
        .where((p) {
          final match = _lineItemPattern.firstMatch(p);
          return match != null && (match.group(2)?.trim() ?? '') != itemName;
        })
        .join(', ');

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Time badge
          Container(
            width: 58,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: Colors.amber.shade50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.amber.shade200),
            ),
            child: Column(
              children: [
                Text(
                  time,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.amber.shade900,
                  ),
                ),
                Text(
                  "#$sequence",
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),

          const SizedBox(width: 12),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      "${occurrence.qty} pcs",
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Colors.deepOrange,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      "${occurrence.receiptTotal.toStringAsFixed(0)} MMK",
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.green.shade700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  // The amount above is the WHOLE receipt, not this item's
                  // share — `sales` stores one total, not per-line prices.
                  others.isEmpty
                      ? "Sold on its own"
                      : "With: $others",
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // =========================================================================
  // LIST VIEWS
  // =========================================================================

  Widget _buildBottomLoader() {
    if (_isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (!_hasMoreData && _dateSummaries.isNotEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text(
            "No more transaction records.",
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildSoldItemSearchBox() {
    if (!_showDailyItemTotals) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextField(
        controller: _soldItemSearchController,
        decoration: InputDecoration(
          hintText: _selectedFilterDateText == null
              ? "Search sold item in loaded days"
              : "Search sold item on $_selectedFilterDateText",
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _soldItemSearchText.trim().isEmpty
              ? null
              : IconButton(
                  onPressed: _clearSoldItemSearch,
                  icon: const Icon(Icons.close),
                ),
          filled: true,
          fillColor: Colors.white,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
        ),
        onChanged: (value) {
          setState(() {
            _soldItemSearchText = value;
          });
        },
      ),
    );
  }

  Widget _buildDateHeader({
    required String dateHeader,
    required double dailyAmount,
    required Color color,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color,
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
              "Total: ${dailyAmount.toStringAsFixed(0)} MMK",
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.green.shade800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDailyItemTotalsView() {
    return ListView.builder(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: _dateSummaries.length + 1,
      itemBuilder: (context, dateIndex) {
        if (dateIndex == _dateSummaries.length) {
          return _buildBottomLoader();
        }

        final summary = _dateSummaries[dateIndex];
        final String dateHeader =
            summary['dateKey']?.toString() ?? 'Unknown Date';

        final List<Map<String, dynamic>> dailySales =
            _salesByDate[dateHeader] ?? [];

        final Map<String, int> itemTotals =
            _buildItemTotalsForSales(dailySales);

        final List<MapEntry<String, int>> entries =
            _filterSoldItemEntries(itemTotals);

        final double dailyAmount = _toDouble(summary['totalAmount']);

        final bool isSearching = _soldItemSearchText.trim().isNotEmpty;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDateHeader(
              dateHeader: dateHeader,
              dailyAmount: dailyAmount,
              color: Colors.orange.shade100,
            ),

            if (entries.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8, left: 4),
                child: Text(
                  isSearching
                      ? "No sold item matched '${_soldItemSearchText.trim()}' on this day."
                      : "No item total details.",
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              )
            else
              ...entries.map((entry) {
                return Card(
                  color: Colors.white,
                  elevation: 0.5,
                  margin: const EdgeInsets.only(bottom: 6),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    dense: true,
                    onTap: () => _showSoldItemDetail(
                      itemName: entry.key,
                      dateHeader: dateHeader,
                      dailySales: dailySales,
                    ),
                    leading: const Icon(Icons.inventory_2, color: Colors.orange),
                    title: Text(
                      entry.key,
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    subtitle: Text(
                      "Tap to see when it sold",
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade500,
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          "${entry.value} pcs",
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.deepOrange,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.chevron_right,
                          size: 18,
                          color: Colors.grey.shade400,
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
  }

  Widget _buildFullArchiveView() {
    return ListView.builder(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: _dateSummaries.length + 1,
      itemBuilder: (context, dateIndex) {
        if (dateIndex == _dateSummaries.length) {
          return _buildBottomLoader();
        }

        final summary = _dateSummaries[dateIndex];
        final String dateHeader =
            summary['dateKey']?.toString() ?? 'Unknown Date';

        final List<Map<String, dynamic>> dailySales =
            _salesByDate[dateHeader] ?? [];

        final double dailyAmount = _toDouble(summary['totalAmount']);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDateHeader(
              dateHeader: dateHeader,
              dailyAmount: dailyAmount,
              color: Colors.grey.shade300,
            ),

            ...dailySales.map((saleRecord) {
              final String timeDisplay =
                  ShopTime.timeOf(saleRecord['saleDate']);

              final double price = _toDouble(saleRecord['price']);

              return Card(
                color: Colors.white,
                elevation: 0.5,
                margin: const EdgeInsets.only(bottom: 6),
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.receipt_long, color: Colors.green),
                  title: Text(
                    "${saleRecord['type']}",
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  subtitle: Text(
                    "Time: $timeDisplay",
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: Text(
                    "${price.toStringAsFixed(0)} MMK",
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.green,
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

  String _emptyMessage() {
    if (_selectedFilterDateText != null) {
      return "No transactions found on $_selectedFilterDateText";
    }
    return "No transaction history records discovered yet.";
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _soldItemSearchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool hasDateFilter = _selectedFilterDateText != null;

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
            icon: const Icon(Icons.calendar_month),
          ),
          if (hasDateFilter)
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
                        if (!value) {
                          _soldItemSearchText = '';
                          _soldItemSearchController.clear();
                        }
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

              _buildSoldItemSearchBox(),

              const SizedBox(height: 12),

              Expanded(
                child: RefreshIndicator(
                  key: _refreshKey,
                  onRefresh: _loadInitialSales,
                  child: _isInitialLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _dateSummaries.isEmpty
                          ? ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              children: [
                                const SizedBox(height: 100),
                                Center(
                                  child: Text(
                                    _emptyMessage(),
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(color: Colors.grey),
                                  ),
                                ),
                              ],
                            )
                          : _showDailyItemTotals
                              ? _buildDailyItemTotalsView()
                              : _buildFullArchiveView(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}