import 'package:flutter/material.dart';

typedef OwnerDashboardApiCall = Future<Map<String, dynamic>> Function(
    String method, String path, [Map<String, dynamic>? body]);

int _count(dynamic value) => value is num ? value.toInt() : int.tryParse('$value') ?? 0;
T? _firstOrNull<T>(Iterable<T> values) {
  for (final value in values) {
    return value;
  }
  return null;
}
String _idOf(dynamic value) {
  if (value is Map) return (value['_id'] ?? value['id'] ?? '').toString();
  return (value ?? '').toString();
}


class _OwnerMetricCard extends StatelessWidget {
  const _OwnerMetricCard({required this.label, required this.value, required this.icon});
  final String label;
  final String value;
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(clipBehavior: Clip.antiAlias, child: Padding(
      padding: const EdgeInsets.all(14),
      child: Row(children: [
        Container(width: 42, height: 42, decoration: BoxDecoration(color: colors.primaryContainer, borderRadius: BorderRadius.circular(12)), child: Icon(icon, color: colors.onPrimaryContainer)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 3),
          Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
        ])),
      ]),
    ));
  }
}

class _OwnerSectionHeading extends StatelessWidget {
  const _OwnerSectionHeading(this.title, {this.subtitle});
  final String title;
  final String? subtitle;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 10),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
      if (subtitle != null) ...[
        const SizedBox(height: 3),
        Text(subtitle!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ],
    ]),
  );
}

class _OwnerActionTile extends StatelessWidget {
  const _OwnerActionTile({required this.icon, required this.title, required this.subtitle, required this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Card(child: ListTile(
    leading: CircleAvatar(child: Icon(icon)),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
    subtitle: Text(subtitle),
    trailing: const Icon(Icons.arrow_forward_ios, size: 15),
    onTap: onTap,
  ));
}

IconData _businessMetricIcon(String label) {
  switch (label) {
    case 'Customers': return Icons.people_alt_outlined;
    case 'Active products / services': return Icons.inventory_2_outlined;
    case 'Business documents': return Icons.receipt_long_outlined;
    case 'Open tasks': return Icons.task_alt_outlined;
    case 'Open support cases': return Icons.support_agent_outlined;
    case 'Branches': return Icons.store_mall_directory_outlined;
    case 'Low-stock items': return Icons.warning_amber_rounded;
    default: return Icons.insights_outlined;
  }
}

IconData _schoolMetricIcon(String label) {
  switch (label) {
    case 'Students': return Icons.groups_2_outlined;
    case 'Attendance records': return Icons.fact_check_outlined;
    case 'School members': return Icons.badge_outlined;
    case 'Fee balances': return Icons.account_balance_wallet_outlined;
    default: return Icons.insights_outlined;
  }
}


class SchoolOwnerDashboard extends StatefulWidget {
  const SchoolOwnerDashboard({
    super.key,
    required this.apiCall,
    required this.currentUserId,
    required this.onManage,
    this.onViewReceipts,
  });
  final OwnerDashboardApiCall apiCall;
  final String currentUserId;
  final VoidCallback onManage;
  final VoidCallback? onViewReceipts;

  @override
  State<SchoolOwnerDashboard> createState() => _SchoolOwnerDashboardState();
}

class _SchoolOwnerDashboardState extends State<SchoolOwnerDashboard> {
  List<Map<String, dynamic>> _ownedSchools = [];
  Map<String, dynamic>? _school;
  Map<String, int> _metrics = {};
  Map<String, dynamic> _billing = {};
  bool _billingLocked = false;
  bool _billingBusy = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({String? schoolId}) async {
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      final result = await widget.apiCall('GET', '/api/schools');
      final all = List<Map<String, dynamic>>.from(
        (result['schools'] as List? ?? const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)),
      );
      final owned = all.where((s) => s['isOwner'] == true && s['role'] == 'admin').toList();
      final selected = _firstOrNull(owned.where((s) => s['id'].toString() == schoolId)) ??
          (_school == null ? null : _firstOrNull(owned.where((s) => s['id'].toString() == _school!['id'].toString()))) ??
          (owned.isEmpty ? null : owned.first);
      if (selected == null) {
        if (mounted) setState(() { _ownedSchools = owned; _school = null; _metrics = {}; _billing = {}; _billingLocked = false; _loading = false; });
        return;
      }
      final id = Uri.encodeComponent(selected['id'].toString());
      final billingResult = await widget.apiCall(
          'GET', '/api/workspace-billing/school/$id');
      final billing = Map<String, dynamic>.from(billingResult['billing'] ?? {});
      if (billing['locked'] == true) {
        if (mounted) setState(() {
          _ownedSchools = owned;
          _school = selected;
          _billing = billing;
          _billingLocked = true;
          _metrics = {};
          _loading = false;
        });
        return;
      }
      final results = await Future.wait([
        widget.apiCall('GET', '/api/schools/$id/students?page=1&limit=1'),
        widget.apiCall('GET', '/api/schools/$id/attendance?page=1&limit=1'),
        widget.apiCall('GET', '/api/schools/$id/members?page=1&limit=1'),
        widget.apiCall('GET', '/api/schools/$id/fee-balances?page=1&limit=1'),
      ]);
      if (!mounted) return;
      setState(() {
        _ownedSchools = owned;
        _school = selected;
        _billing = billing;
        _billingLocked = false;
        _metrics = {
          'Students': _count(results[0]['total']),
          'Attendance records': _count(results[1]['total']),
          'School members': _count(results[2]['total']),
          'Fee balances': _count(results[3]['total']),
        };
        _loading = false;
      });
    } catch (error) {
      if (mounted) setState(() { _error = error.toString(); _loading = false; });
    }
  }

  Future<void> _payWorkspaceBilling(String billingType) async {
    final school = _school;
    if (school == null || _billingBusy || _loading) return;
    var enteredPhone = '';
    final phone = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('School workspace payment'),
        content: TextField(
          keyboardType: TextInputType.phone,
          onChanged: (value) => enteredPhone = value,
          decoration: const InputDecoration(
            labelText: 'M-Pesa phone number',
            hintText: '07XXXXXXXX or 2547XXXXXXXX',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, enteredPhone.trim()),
            child: const Text('Continue to M-Pesa'),
          ),
        ],
      ),
    );
    if (phone == null || phone.isEmpty || !mounted) return;
    setState(() => _billingBusy = true);
    try {
      final id = Uri.encodeComponent(school['id'].toString());
      final checkout = await widget.apiCall(
        'POST',
        '/api/workspace-billing/school/$id/checkout',
        {'billingType': billingType},
      );
      if (checkout['paid'] == true) {
        await _load(schoolId: school['id'].toString());
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(checkout['notice']?.toString() ?? 'School billing updated.'),
        ));
        return;
      }
      final payment = Map<String, dynamic>.from(checkout['payment'] ?? {});
      final paymentId = payment['paymentId']?.toString();
      if (paymentId == null || paymentId.isEmpty) {
        throw Exception('The school billing checkout did not return a payment reference.');
      }
      if (payment['initiatedAt'] == null) {
        await widget.apiCall(
          'POST',
          '/api/payments/${Uri.encodeComponent(paymentId)}/initiate',
          {'phone': phone},
        );
      }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('M-Pesa prompt requested. Approve it on your phone; school access unlocks only after provider confirmation.'),
      ));
      for (var attempt = 0; attempt < 20 && mounted; attempt++) {
        await Future.delayed(const Duration(seconds: 3));
        final statusResult = await widget.apiCall(
          'GET',
          '/api/payments/${Uri.encodeComponent(paymentId)}',
        );
        final current = Map<String, dynamic>.from(statusResult['payment'] ?? {});
        final status = current['status']?.toString().toUpperCase();
        if (status == 'SUCCESS') {
          await _load(schoolId: school['id'].toString());
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Payment confirmed. School workspace access refreshed.'),
          ));
          return;
        }
        if (status == 'FAILED' || status == 'CANCELLED') {
          throw Exception('M-Pesa payment $status. Refresh billing before retrying.');
        }
      }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Payment is still pending. Refresh billing shortly; do not pay again unless the first payment has failed.'),
      ));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    } finally {
      if (mounted) setState(() => _billingBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final school = _school;
    return Scaffold(
      appBar: AppBar(
        title: const Text('School owner dashboard'),
        actions: [IconButton(tooltip: 'Refresh dashboard', onPressed: _loading ? null : () => _load(), icon: const Icon(Icons.refresh))],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            if (_loading) const LinearProgressIndicator(),
            if (_error != null) Card(child: ListTile(leading: const Icon(Icons.error_outline), title: const Text('Could not load school overview'), subtitle: Text(_error!))),
            if (!_loading && school == null) ...[
              const Card(child: ListTile(leading: Icon(Icons.school_outlined), title: Text('No school owned by this account'), subtitle: Text('School owners see their own school overview here. Staff and parents can continue to the school workspace using the button below.'))),
              FilledButton.icon(onPressed: widget.onManage, icon: const Icon(Icons.open_in_new), label: const Text('Open school workspace')),
            ],
            if (school != null) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(school['name']?.toString() ?? 'School', style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 6),
                    Text('School code: ${school['code'] ?? 'Not available'}'),
                    Text('Owner access verified by the school membership response'),
                    if (_ownedSchools.length > 1) ...[
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        key: ValueKey('school-owner-selector-${school['id']}'),
                        initialValue: school['id'].toString(),
                        decoration: const InputDecoration(labelText: 'Owned school'),
                        items: _ownedSchools.map((s) => DropdownMenuItem<String>(value: s['id'].toString(), child: Text(s['name']?.toString() ?? 'School'))).toList(),
                        onChanged: (value) { if (value != null) _load(schoolId: value); },
                      ),
                    ],
                  ]),
                ),
              ),
              if (_billing.isNotEmpty)
                Card(child: ListTile(
                  leading: Icon(_billingLocked ? Icons.lock_outline : Icons.workspace_premium_outlined),
                  title: Text(_billingLocked ? 'School workspace payment required' : 'School workspace billing'),
                  subtitle: Text('Status: ${_billing['status'] ?? 'Unknown'} · Setup fee: ${_billing['setupFeePaid'] == true ? 'Paid' : 'Unpaid'}'),
                )),
              if (_billingLocked) ...[
                Card(child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.lock_outline),
                      title: Text('School workspace is locked'),
                      subtitle: Text('School records remain protected until the required Chatify setup fee or subscription payment is confirmed.'),
                    ),
                    if (_billingBusy || _loading) const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: _billingBusy ? null : () => _payWorkspaceBilling(
                        _billing['setupFeePaid'] == true ? 'workspace_subscription' : 'workspace_setup',
                      ),
                      icon: const Icon(Icons.payment),
                      label: Text(_billing['setupFeePaid'] == true
                        ? 'Pay monthly · KSh ${_count((_billing['prices'] as Map?)?['monthlyFee'] ?? 2500)}'
                        : 'Pay setup · KSh ${_count((_billing['prices'] as Map?)?['setupFee'] ?? 5000)}'),
                    ),
                    const SizedBox(height: 4),
                    const Text('Access refreshes only after the payment API confirms success. School fee collections and donations are separate from this Chatify subscription.'),
                  ]),
                )),
              ],
              if (!_billingLocked) ...[
              Text('School overview', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              LayoutBuilder(builder: (context, constraints) {
                final columns = constraints.maxWidth >= 720 ? 4 : constraints.maxWidth >= 440 ? 2 : 1;
                return GridView.count(
                  crossAxisCount: columns,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  childAspectRatio: columns == 1 ? 3.2 : 1.55,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  children: _metrics.entries.map((entry) => _OwnerMetricCard(
                    label: entry.key,
                    value: entry.value.toString(),
                    icon: _schoolMetricIcon(entry.key),
                  )).toList(),
                );
              }),
              const _OwnerSectionHeading('School operations', subtitle: 'Quick access to the areas that keep your school running.'),
              _OwnerActionTile(icon: Icons.groups_2_outlined, title: 'Students & admissions', subtitle: 'Review student records and enrolment', onTap: widget.onManage),
              _OwnerActionTile(icon: Icons.fact_check_outlined, title: 'Attendance', subtitle: 'Open class and daily attendance records', onTap: widget.onManage),
              _OwnerActionTile(icon: Icons.account_balance_wallet_outlined, title: 'Fees & balances', subtitle: 'Review fee accounts and outstanding balances', onTap: widget.onManage),
              _OwnerActionTile(icon: Icons.receipt_long_outlined, title: 'Pupil fee receipts', subtitle: 'View and download confirmed receipts for pupils across this school', onTap: widget.onViewReceipts ?? widget.onManage),
              _OwnerActionTile(icon: Icons.badge_outlined, title: 'Staff & school members', subtitle: 'Manage the people connected to your school', onTap: widget.onManage),
              const _OwnerSectionHeading('Account & data protection'),
              const Card(child: ListTile(leading: Icon(Icons.verified_user_outlined), title: Text('School data protection'), subtitle: Text('Student and school records are loaded through authenticated school APIs. Server membership and linked-student checks remain authoritative.'))),
              FilledButton.icon(onPressed: widget.onManage, icon: const Icon(Icons.dashboard_customize_outlined), label: const Text('Manage school workspace')),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class BusinessOwnerDashboard extends StatefulWidget {
  const BusinessOwnerDashboard({
    super.key,
    required this.apiCall,
    required this.currentUserId,
    required this.onManage,
  });
  final OwnerDashboardApiCall apiCall;
  final String currentUserId;
  final VoidCallback onManage;

  @override
  State<BusinessOwnerDashboard> createState() => _BusinessOwnerDashboardState();
}

class _BusinessOwnerDashboardState extends State<BusinessOwnerDashboard> {
  List<Map<String, dynamic>> _owned = [];
  Map<String, dynamic>? _organization;
  Map<String, dynamic> _metrics = {};
  Map<String, dynamic> _billing = {};
  bool _billingLocked = false;
  bool _billingBusy = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load({String? organizationId}) async {
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      final response = await widget.apiCall('GET', '/api/business/organizations');
      final all = List<Map<String, dynamic>>.from(
        (response['organizations'] as List? ?? const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)),
      );
      final owned = all.where((org) => _idOf(org['ownerId']) == widget.currentUserId).toList();
      final selected = _firstOrNull(owned.where((org) => _idOf(org['_id']) == organizationId)) ??
          (_organization == null ? null : _firstOrNull(owned.where((org) => _idOf(org['_id']) == _idOf(_organization!['_id'])))) ??
          (owned.isEmpty ? null : owned.first);
      if (selected == null) {
        if (mounted) setState(() { _owned = owned; _organization = null; _metrics = {}; _billing = {}; _billingLocked = false; _loading = false; });
        return;
      }
      final id = Uri.encodeComponent(_idOf(selected['_id']));
      final billingResult = await widget.apiCall('GET', '/api/workspace-billing/business/$id');
      final billing = Map<String, dynamic>.from(billingResult['billing'] ?? {});
      if (billing['locked'] == true) {
        if (mounted) setState(() {
          _owned = owned;
          _organization = selected;
          _billing = billing;
          _billingLocked = true;
          _metrics = {};
          _loading = false;
        });
        return;
      }
      final result = await widget.apiCall('GET', '/api/business/organizations/$id/dashboard');
      if (!mounted) return;
      setState(() {
        _owned = owned;
        _organization = selected;
        _billing = billing;
        _billingLocked = false;
        _metrics = Map<String, dynamic>.from(result['metrics'] ?? {});
        _loading = false;
      });
    } catch (error) {
      if (mounted) setState(() { _error = error.toString(); _loading = false; });
    }
  }

  Future<void> _payWorkspaceBilling(String billingType) async {
    final organization = _organization;
    if (organization == null || _billingBusy || _loading) return;
    final approval = (organization['approvalStatus'] ?? 'APPROVED').toString().toUpperCase();
    if (approval != 'APPROVED') {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Workspace payment becomes available after platform approval.'),
      ));
      return;
    }
    var enteredPhone = '';
    final phone = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Business workspace payment'),
        content: TextField(
          keyboardType: TextInputType.phone,
          onChanged: (value) => enteredPhone = value,
          decoration: const InputDecoration(
            labelText: 'M-Pesa phone number',
            hintText: '07XXXXXXXX or 2547XXXXXXXX',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, enteredPhone.trim()),
            child: const Text('Continue to M-Pesa'),
          ),
        ],
      ),
    );
    if (phone == null || phone.isEmpty || !mounted) return;
    setState(() => _billingBusy = true);
    try {
      final id = Uri.encodeComponent(_idOf(organization['_id']));
      final checkout = await widget.apiCall(
        'POST',
        '/api/workspace-billing/business/$id/checkout',
        {'billingType': billingType},
      );
      if (checkout['paid'] == true) {
        await _load(organizationId: _idOf(organization['_id']));
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(checkout['notice']?.toString() ?? 'Business billing updated.'),
        ));
        return;
      }
      final payment = Map<String, dynamic>.from(checkout['payment'] ?? {});
      final paymentId = payment['paymentId']?.toString();
      if (paymentId == null || paymentId.isEmpty) {
        throw Exception('The billing checkout did not return a payment reference.');
      }
      if (payment['initiatedAt'] == null) {
        await widget.apiCall(
          'POST',
          '/api/payments/${Uri.encodeComponent(paymentId)}/initiate',
          {'phone': phone},
        );
      }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('M-Pesa prompt requested. Approve it on your phone; the business workspace unlocks only after provider confirmation.'),
      ));
      for (var attempt = 0; attempt < 20 && mounted; attempt++) {
        await Future.delayed(const Duration(seconds: 3));
        final statusResult = await widget.apiCall(
          'GET',
          '/api/payments/${Uri.encodeComponent(paymentId)}',
        );
        final current = Map<String, dynamic>.from(statusResult['payment'] ?? {});
        final status = current['status']?.toString().toUpperCase();
        if (status == 'SUCCESS') {
          await _load(organizationId: _idOf(organization['_id']));
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Payment confirmed. Business workspace access refreshed.'),
          ));
          return;
        }
        if (status == 'FAILED' || status == 'CANCELLED') {
          throw Exception('M-Pesa payment $status. Refresh billing before retrying.');
        }
      }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Payment is still pending. Refresh billing shortly; do not pay again unless the first payment has failed.'),
      ));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    } finally {
      if (mounted) setState(() => _billingBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final organization = _organization;
    final values = <String, dynamic>{
      'Customers': _metrics['customers'] ?? 0,
      'Active products / services': _metrics['activeCatalogItems'] ?? 0,
      'Business documents': _metrics['documents'] ?? 0,
      'Open tasks': _metrics['openTasks'] ?? 0,
      'Open support cases': _metrics['openCases'] ?? 0,
      'Branches': (organization?['branches'] as List?)?.length ?? 0,
      'Low-stock items': (_metrics['lowStockItems'] as List?)?.length ?? 0,
    };
    return Scaffold(
      appBar: AppBar(
        title: const Text('Business owner dashboard'),
        actions: [IconButton(tooltip: 'Refresh dashboard', onPressed: _loading ? null : () => _load(), icon: const Icon(Icons.refresh))],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            if (_loading) const LinearProgressIndicator(),
            if (_error != null) Card(child: ListTile(leading: const Icon(Icons.error_outline), title: const Text('Could not load business overview'), subtitle: Text(_error!))),
            if (!_loading && organization == null) ...[
              const Card(child: ListTile(leading: Icon(Icons.business_outlined), title: Text('No business owned by this account'), subtitle: Text('Business owners see their own organization overview here. Managers and staff can continue to the business workspace using the button below.'))),
              FilledButton.icon(onPressed: widget.onManage, icon: const Icon(Icons.open_in_new), label: const Text('Open business workspace')),
            ],
            if (organization != null) ...[
              Card(child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(organization['name']?.toString() ?? 'Business', style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 6),
                  Text('Industry: ${organization['industry'] ?? 'Not set'}'),
                  Text('Currency: ${organization['currency'] ?? 'Not set'}'),
                  if (_owned.length > 1) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      key: ValueKey('business-owner-selector-${_idOf(organization['_id'])}'),
                      initialValue: _idOf(organization['_id']),
                      decoration: const InputDecoration(labelText: 'Owned business'),
                      items: _owned.map((org) => DropdownMenuItem<String>(value: _idOf(org['_id']), child: Text(org['name']?.toString() ?? 'Business'))).toList(),
                      onChanged: (value) { if (value != null) _load(organizationId: value); },
                    ),
                  ],
                ]),
              )),
              if (_billing.isNotEmpty) ...[
                Card(child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(_billingLocked ? Icons.lock_outline : Icons.workspace_premium_outlined),
                      const SizedBox(width: 8),
                      Expanded(child: Text('Business workspace billing', style: Theme.of(context).textTheme.titleMedium)),
                      if (_billingBusy || _loading) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    ]),
                    const SizedBox(height: 6),
                    Text('Status: ${_billing['status'] ?? 'Unknown'} · Setup fee: ${_billing['setupFeePaid'] == true ? 'Paid' : 'Unpaid'}'),
                    if (organization['approvalStatus']?.toString().toUpperCase() == 'PENDING')
                      const Text('Awaiting Chatify platform approval. Setup payment becomes available after approval.'),
                    if (organization['approvalStatus']?.toString().toUpperCase() == 'REJECTED')
                      const Text('This business application was rejected. Contact Chatify support before subscribing.'),
                    if (_billingLocked && organization['approvalStatus']?.toString().toUpperCase() == 'APPROVED') ...[
                      const SizedBox(height: 8),
                      Text(_billing['setupFeePaid'] == true
                        ? 'The monthly workspace subscription must be paid before business operations unlock.'
                        : 'The one-time setup fee must be confirmed before business operations unlock.'),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed: _billingBusy ? null : () => _payWorkspaceBilling(_billing['setupFeePaid'] == true ? 'workspace_subscription' : 'workspace_setup'),
                        icon: const Icon(Icons.payment),
                        label: Text(_billing['setupFeePaid'] == true
                          ? 'Pay monthly · KSh ${_count((_billing['prices'] as Map?)?['monthlyFee'] ?? 500)}'
                          : 'Pay setup · KSh ${_count((_billing['prices'] as Map?)?['setupFee'] ?? 1000)}'),
                      ),
                    ],
                    if (!_billingLocked)
                      const Text('Workspace billing is currently within its access window. Customer sales and merchant payments are separate from this Chatify subscription.'),
                  ]),
                )),
              ],
              if (_billingLocked) ...[
                const Card(child: ListTile(
                  leading: Icon(Icons.lock_outline),
                  title: Text('Business operations are locked'),
                  subtitle: Text('The business identity is retained, but its operational records remain protected until the required subscription payment is confirmed.'),
                )),
                FilledButton.icon(onPressed: widget.onManage, icon: const Icon(Icons.open_in_new), label: const Text('Open business workspace')),
              ],
              if (!_billingLocked) ...[
              Text('Business overview', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              LayoutBuilder(builder: (context, constraints) {
                final columns = constraints.maxWidth >= 900 ? 4 : constraints.maxWidth >= 560 ? 3 : constraints.maxWidth >= 360 ? 2 : 1;
                return GridView.count(
                  crossAxisCount: columns,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  childAspectRatio: 1.65,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  children: values.entries.map((entry) => _OwnerMetricCard(
                    label: entry.key,
                    value: _count(entry.value).toString(),
                    icon: _businessMetricIcon(entry.key),
                  )).toList(),
                );
              }),
              const _OwnerSectionHeading('Operational focus', subtitle: 'Items that may need your attention.'),
              if ((_metrics['briefing'] ?? '').toString().trim().isNotEmpty)
                Card(child: ListTile(leading: const Icon(Icons.auto_awesome_outlined), title: const Text('Owner briefing'), subtitle: Text(_metrics['briefing'].toString()))),
              if ((_metrics['lowStockItems'] as List? ?? const []).isNotEmpty)
                Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [const Icon(Icons.inventory_2_outlined), const SizedBox(width: 8), Expanded(child: Text('Low-stock watchlist', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))), Text('${(_metrics['lowStockItems'] as List).length}', style: Theme.of(context).textTheme.titleMedium)]),
                  const SizedBox(height: 8),
                  ...(_metrics['lowStockItems'] as List).whereType<Map>().take(5).map((item) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.warning_amber_rounded),
                    title: Text((item['name'] ?? 'Unnamed item').toString()),
                    subtitle: Text('Stock: ${item['stock'] ?? '—'} · Reorder level: ${item['lowStockAt'] ?? '—'}'),
                  )),
                ]))),
              if ((_metrics['lowStockItems'] as List? ?? const []).isEmpty)
                const Card(child: ListTile(leading: Icon(Icons.check_circle_outline), title: Text('No low-stock alerts'), subtitle: Text('No catalogue items are currently below their configured reorder level.'))),
              const _OwnerSectionHeading('Manage your business', subtitle: 'Open the workspace to complete these day-to-day tasks.'),
              _OwnerActionTile(icon: Icons.point_of_sale_outlined, title: 'Sales & documents', subtitle: 'Create and review invoices, orders and sales records', onTap: widget.onManage),
              _OwnerActionTile(icon: Icons.people_alt_outlined, title: 'Customers', subtitle: 'Manage customer profiles and relationships', onTap: widget.onManage),
              _OwnerActionTile(icon: Icons.inventory_2_outlined, title: 'Products & stock', subtitle: 'Update your catalogue and stock levels', onTap: widget.onManage),
              _OwnerActionTile(icon: Icons.task_alt_outlined, title: 'Tasks & support cases', subtitle: 'Follow up on outstanding work and customer issues', onTap: widget.onManage),
              const Card(child: ListTile(leading: Icon(Icons.verified_user_outlined), title: Text('Workspace privacy'), subtitle: Text('Only organizations whose owner ID matches the authenticated account are shown here. API membership and organization checks remain authoritative.'))),
              FilledButton.icon(onPressed: widget.onManage, icon: const Icon(Icons.dashboard_customize_outlined), label: const Text('Manage business workspace')),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
