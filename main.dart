void _collectYearlyDialog(Map<String, dynamic> member) {
  int targetYear = _curYear;
  final rate = member['rate'] as int;
  final yearlyTotalTaka = (rate * 12) ~/ 100;
  final amountCtrl = TextEditingController(
    text: yearlyTotalTaka.toString(),
  );

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDState) => AlertDialog(
        title: Text('${member['name']} — বাৎসরিক চাঁদা'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('মাসিক চাঁদা: ${BanglaHelper.formatTaka(rate)}'),
              Text('১২ মাসের চাঁদা: ৳ ${BanglaHelper.toBn(yearlyTotalTaka)}'),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                value: targetYear,
                decoration: const InputDecoration(
                  labelText: 'কোন সালের চাঁদা',
                ),
                items: [_curYear - 1, _curYear, _curYear + 1]
                    .map((y) => DropdownMenuItem(
                          value: y,
                          child: Text(BanglaHelper.toBn(y)),
                        ))
                    .toList(),
                onChanged: (val) {
                  if (val != null) {
                    setDState(() => targetYear = val);
                  }
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: amountCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'গৃহীত টাকার পরিমাণ',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('বাতিল'),
          ),
          ElevatedButton(
            onPressed: () async {
              final totalTaka = int.tryParse(amountCtrl.text) ?? 0;
              if (totalTaka <= 0) return;

              final totalPaisa = totalTaka * 100;
              final basePaisa = totalPaisa ~/ 12;
              final remainder = totalPaisa % 12;

              final rNo =
                  'Y-RCP-${DateTime.now().millisecondsSinceEpoch}';
              final now = DateTime.now().toIso8601String();

              await _db!.transaction((txn) async {
                for (int m = 1; m <= 12; m++) {
                  await txn.insert('collections', {
                    'member_id': member['id'],
                    'year': targetYear,
                    'month': m,
                    'amount': basePaisa + (m <= remainder ? 1 : 0),
                    'receipt_no': rNo,
                    'date': now,
                    'type': 'YEARLY',
                    'note': 'বাৎসরিক এককালীন চাঁদা',
                  });
                }
              });

              if (!ctx.mounted) return;

              Navigator.pop(ctx);
              await _loadData();

              if (!mounted) return;

              _showDigitalReceipt(
                name: member['name'],
                phone: member['phone'],
                amountPaisa: totalPaisa,
                receiptNo: rNo,
                periodText:
                    '${BanglaHelper.toBn(targetYear)} সালের পুরো বছর (১২ মাস)',
              );
            },
            child: const Text('১ বছরের চাঁদা জমা নিন'),
          ),
        ],
      ),
    ),
  );
}