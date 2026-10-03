import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

class ApiException implements Exception {
  final int statusCode;
  final String message;
  const ApiException(this.statusCode, this.message);
  @override
  String toString() => message;
}

class Api {
  final http.Client client;
  Api({http.Client? client}) : client = client ?? http.Client();
  String get base => const String.fromEnvironment('CHATIFY_API',
      defaultValue: 'http://10.0.2.2:5000');
  String? token;
  Future<void> restore() async {
    token = (await SharedPreferences.getInstance()).getString('token');
  }

  Future<Map<String, dynamic>> call(String method, String path,
      [Map<String, dynamic>? body]) async {
    final h = {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token'
    };
    final u = Uri.parse('$base$path');
    late http.Response r;
    if (method == 'POST') {
      r = await client
          .post(u, headers: h, body: jsonEncode(body ?? {}))
          .timeout(const Duration(seconds: 20));
    } else if (method == 'PATCH') {
      r = await client
          .patch(u, headers: h, body: jsonEncode(body ?? {}))
          .timeout(const Duration(seconds: 20));
    } else if (method == 'DELETE') {
      r = await client.delete(u, headers: h).timeout(const Duration(seconds: 20));
    } else {
      r = await client.get(u, headers: h).timeout(const Duration(seconds: 20));
    }
    final d = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body);
    if (r.statusCode >= 400) {
      throw ApiException(r.statusCode,
          d is Map && d['error'] != null ? d['error'] : 'Request failed');
    }
    return d is Map ? Map<String, dynamic>.from(d) : {'data': d};
  }
}

List<dynamic> mergeMessages(List<dynamic> current, List<dynamic> fetched) {
  final merged = <dynamic>[];
  final indices = <String, int>{};
  for (final message in [...current, ...fetched]) {
    if (message is! Map || message['_id'] == null) {
      merged.add(message);
      continue;
    }
    final id = message['_id'].toString();
    final index = indices[id];
    if (index == null) {
      indices[id] = merged.length;
      merged.add(message);
    } else {
      merged[index] = message;
    }
  }
  merged.sort((a, b) {
    if (a is! Map || b is! Map) return 0;
    final aDate = DateTime.tryParse(a['createdAt']?.toString() ?? '');
    final bDate = DateTime.tryParse(b['createdAt']?.toString() ?? '');
    if (aDate == null || bDate == null) return 0;
    return aDate.compareTo(bDate);
  });
  return merged;
}

class AppState extends ChangeNotifier {
  final Api api;
  bool ready = false;
  Map<String, dynamic>? user;
  String? restoreError;
  AppState({Api? api, bool autoInit = true}) : api = api ?? Api() {
    if (autoInit) init();
  }
  Future<void> init() async {
    ready = false;
    restoreError = null;
    await api.restore();
    if (api.token != null) {
      try {
        user = Map<String, dynamic>.from(
            (await api.call('GET', '/api/auth/me'))['user']);
      } catch (error) {
        if (error is ApiException && error.statusCode == 401) {
          await logout();
        } else {
          restoreError = error.toString();
        }
      }
    }
    ready = true;
    notifyListeners();
  }

  Future<String?> auth(bool reg, String name, String email, String pass) async {
    try {
      final d = await api.call(
          'POST',
          reg ? '/api/auth/register' : '/api/auth/login',
          reg
              ? {'name': name, 'email': email, 'password': pass}
              : {'email': email, 'password': pass});
      api.token = d['token'];
      user = Map<String, dynamic>.from(d['user']);
      await (await SharedPreferences.getInstance())
          .setString('token', api.token!);
      notifyListeners();
      return null;
    } catch (e) {
      return e.toString().replaceFirst('Exception: ', '');
    }
  }

  Future<void> logout() async {
    api.token = null;
    user = null;
    restoreError = null;
    await (await SharedPreferences.getInstance()).remove('token');
    notifyListeners();
  }
}

void main() => runApp(ChangeNotifierProvider(
    create: (_) => AppState(), child: const ChatifyApp()));

class ChatifyApp extends StatelessWidget {
  const ChatifyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Chatify',
      theme: ThemeData(
          useMaterial3: true, colorSchemeSeed: const Color(0xFF6558D3)),
      home: Consumer<AppState>(
          builder: (_, a, __) => !a.ready
              ? const Scaffold(
                  body: Center(child: CircularProgressIndicator()))
              : a.restoreError != null
                  ? Scaffold(
                      body: Center(
                          child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('Could not restore your session.'),
                            const SizedBox(height: 12),
                            Text(a.restoreError!,
                                textAlign: TextAlign.center),
                            const SizedBox(height: 12),
                            FilledButton(
                                onPressed: a.init,
                                child: const Text('Retry'))
                          ]),
                    )))
                  : a.user != null
                      ? const Home()
                      : const Auth()));
}

class Auth extends StatefulWidget {
  const Auth({super.key});
  @override
  State<Auth> createState() => _AuthState();
}

class _AuthState extends State<Auth> {
  bool reg = false, busy = false, hide = true;
  final n = TextEditingController(),
      e = TextEditingController(),
      p = TextEditingController();
  @override
  void dispose() {
    n.dispose();
    e.dispose();
    p.dispose();
    super.dispose();
  }

  Future<void> recover() async {
    final email = TextEditingController(text: e.text.trim());
    final token = TextEditingController();
    final password = TextEditingController();
    var requested = false;
    final key = GlobalKey<FormState>();
    await showDialog<void>(
        context: context,
        builder: (d) => AlertDialog(
                title: const Text('Reset password'),
                content: Form(
                    key: key,
                    child: TextFormField(
                        controller: email,
                        keyboardType: TextInputType.emailAddress,
                        decoration:
                            const InputDecoration(labelText: 'Account email'),
                        validator: (v) => v == null || !v.contains('@')
                            ? 'Enter a valid email'
                            : '')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(d),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () async {
                        if (!key.currentState!.validate()) return;
                        try {
                          await context.read<AppState>().api.call(
                              'POST',
                              '/api/auth/forgot-password',
                              {'email': email.text.trim()});
                          requested = true;
                          if (d.mounted) Navigator.pop(d);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text(
                                        'If the account exists, reset instructions will be sent.')));
                          }
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(e.toString())));
                          }
                        }
                      },
                      child: const Text('Send instructions'))
                ]));
    email.dispose();
    if (requested && mounted) {
      await showDialog<void>(
          context: context,
          builder: (d) => AlertDialog(
                  title: const Text('Choose a new password'),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: token,
                        decoration:
                            const InputDecoration(labelText: 'Reset token')),
                    TextField(
                        controller: password,
                        obscureText: true,
                        decoration: const InputDecoration(
                            labelText: 'New password (8+ characters)'))
                  ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(d),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () async {
                          try {
                            await context.read<AppState>().api.call(
                                'POST', '/api/auth/reset-password', {
                              'token': token.text.trim(),
                              'newPassword': password.text
                            });
                            if (d.mounted) Navigator.pop(d);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          'Password updated. Sign in with your new password.')));
                            }
                          } catch (error) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(error.toString())));
                            }
                          }
                        },
                        child: const Text('Reset password'))
                  ]));
    }
    token.dispose();
    password.dispose();
  }

  Future<void> submit() async {
    if (e.text.trim().isEmpty ||
        p.text.length < 8 ||
        (reg && n.text.trim().isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Complete all fields. Password must be 8+ characters.')));
      return;
    }
    setState(() => busy = true);
    final err = await context
        .read<AppState>()
        .auth(reg, n.text.trim(), e.text.trim(), p.text);
    if (mounted) {
      setState(() => busy = false);
      if (err != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err)));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      body: SafeArea(
          child: Center(
              child: SingleChildScrollView(
                  padding: const EdgeInsets.all(28),
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 430),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Icon(Icons.forum_rounded, size: 70),
                            const SizedBox(height: 10),
                            const Text('Chatify',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 40, fontWeight: FontWeight.w800)),
                            const Text('Chat. Remember. Let Go.',
                                textAlign: TextAlign.center),
                            const SizedBox(height: 30),
                            if (reg)
                              TextField(
                                  controller: n,
                                  autofillHints: const [AutofillHints.name],
                                  decoration: const InputDecoration(
                                      labelText: 'Full name',
                                      border: OutlineInputBorder())),
                            if (reg) const SizedBox(height: 12),
                            TextField(
                                controller: e,
                                keyboardType: TextInputType.emailAddress,
                                autofillHints: const [AutofillHints.email],
                                decoration: const InputDecoration(
                                    labelText: 'Email address',
                                    border: OutlineInputBorder())),
                            const SizedBox(height: 12),
                            TextField(
                                controller: p,
                                obscureText: hide,
                                autofillHints: [
                                  reg
                                      ? AutofillHints.newPassword
                                      : AutofillHints.password
                                ],
                                onSubmitted: (_) => submit(),
                                decoration: InputDecoration(
                                    labelText: 'Password',
                                    border: const OutlineInputBorder(),
                                    suffixIcon: IconButton(
                                        onPressed: () =>
                                            setState(() => hide = !hide),
                                        icon: Icon(hide
                                            ? Icons.visibility
                                            : Icons.visibility_off)))),
                            const SizedBox(height: 18),
                            FilledButton(
                                onPressed: busy ? null : submit,
                                child: busy
                                    ? const SizedBox(
                                        height: 20,
                                        width: 20,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2))
                                    : Text(reg ? 'Create account' : 'Sign in')),
                            if (!reg)
                              TextButton(
                                  onPressed: busy ? null : recover,
                                  child: const Text('Forgot password?')),
                            TextButton(
                                onPressed: () => setState(() => reg = !reg),
                                child: Text(reg
                                    ? 'Already have an account? Sign in'
                                    : 'Create a new account'))
                          ]))))));
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;
  List<dynamic> chats = [], users = [], memories = [];
  bool loading = false;
  bool memoriesLoading = false, usersLoading = false;
  String contactQuery = '';
  String? chatsError, memoriesError, usersError;
  AppState get app => context.read<AppState>();
  @override
  void initState() {
    super.initState();
    loadChats();
  }

  Future<void> loadChats() async {
    setState(() => loading = true);
    try {
      chats = List<dynamic>.from(
          (await app.api.call('GET', '/api/conversations'))['conversations'] ??
              []);
      chatsError = null;
    } catch (error) {
      chatsError = error.toString();
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> search(String q) async {
    contactQuery = q;
    if (q.trim().length < 2) {
      setState(() {
        users = [];
        usersError = null;
        usersLoading = false;
      });
      return;
    }
    setState(() {
      usersLoading = true;
      usersError = null;
    });
    try {
      final found = List<dynamic>.from((await app.api.call('GET',
                  '/api/users/search?q=${Uri.encodeQueryComponent(q.trim())}'))[
              'users'] ??
          []);
      if (mounted && contactQuery == q) setState(() => users = found);
    } catch (error) {
      if (mounted && contactQuery == q) {
        setState(() => usersError = error.toString());
      }
    } finally {
      if (mounted && contactQuery == q) setState(() => usersLoading = false);
    }
  }

  Future<void> loadMemories() async {
    setState(() => memoriesLoading = true);
    try {
      memories = List<dynamic>.from(
          (await app.api.call('GET', '/api/memories'))['memories'] ?? []);
      memoriesError = null;
      if (mounted) setState(() {});
    } catch (error) {
      memoriesError = error.toString();
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => memoriesLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final titles = ['Chats', 'Memories', 'Contacts', 'Profile'];
    return Scaffold(
      appBar: AppBar(
        title: Text(titles[tab]),
        actions: [
          if (tab == 0)
            IconButton(onPressed: loadChats, icon: const Icon(Icons.refresh)),
          if (tab == 2)
            IconButton(onPressed: _newGroup, icon: const Icon(Icons.group_add)),
        ],
      ),
      body: IndexedStack(
          index: tab,
          children: [_chats(), _memories(), _contacts(), const Profile()]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) {
          setState(() => tab = i);
          if (i == 0) loadChats();
          if (i == 1) loadMemories();
        },
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline), label: 'Chats'),
          NavigationDestination(
              icon: Icon(Icons.auto_awesome_outlined), label: 'Memories'),
          NavigationDestination(
              icon: Icon(Icons.people_outline), label: 'Contacts'),
          NavigationDestination(
              icon: Icon(Icons.person_outline), label: 'Profile'),
        ],
      ),
    );
  }

  Widget _chats() {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (chatsError != null) {
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(chatsError!, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        FilledButton(onPressed: loadChats, child: const Text('Retry'))
      ]));
    }
    if (chats.isEmpty) {
      return const Empty(
          icon: Icons.forum_outlined,
          title: 'No conversations',
          subtitle: 'Search Contacts to start a chat.');
    }
    return RefreshIndicator(
      onRefresh: loadChats,
      child: ListView.builder(
        itemCount: chats.length,
        itemBuilder: (_, i) {
          final c = Map<String, dynamic>.from(chats[i]);
          final ps = List<dynamic>.from(c['participants'] ?? []);
          final me = app.user?['id']?.toString();
          Map<String, dynamic>? other;
          for (final raw in ps) {
            final person = Map<String, dynamic>.from(raw);
            if (person['_id']?.toString() != me) {
              other = person;
              break;
            }
          }
          final title = c['type'] == 'group'
              ? (c['title'] ?? 'Group').toString()
              : (other?['name'] ?? 'Chat').toString();
          final last = c['lastMessage'];
          final preview = last is Map
              ? (last['text'] ?? 'Start chatting').toString()
              : 'Start chatting';
          return ListTile(
            leading: CircleAvatar(
                child: Text(title.isEmpty ? '?' : title[0].toUpperCase())),
            title: Text(title),
            subtitle: Text(preview),
            onTap: () {
              Navigator.push(context,
                      MaterialPageRoute(builder: (_) => Chat(conversation: c)))
                  .then((_) => loadChats());
            },
          );
        },
      ),
    );
  }

  Widget _contacts() {
    return Column(children: [
      Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
              onChanged: search,
              decoration: const InputDecoration(
                  labelText: 'Search people',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder()))),
      Expanded(
          child: usersLoading
              ? const Center(child: CircularProgressIndicator())
              : usersError != null
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(usersError!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton(
                          onPressed: () => search(contactQuery),
                          child: const Text('Retry'))
                    ]))
                  : users.isEmpty
                      ? const Empty(
                          icon: Icons.person_search,
                          title: 'Find people',
                          subtitle: 'Search by name or email.')
                      : ListView.builder(
                          itemCount: users.length,
                          itemBuilder: (_, i) {
                            final u = Map<String, dynamic>.from(users[i]);
                            final displayName = u['name']?.toString() ?? 'User';
                            return ListTile(
                              leading: CircleAvatar(
                                  child: Text(displayName.isEmpty
                                      ? '?'
                                      : displayName[0].toUpperCase())),
                              title: Text(displayName),
                              subtitle: Text(u['email']?.toString() ?? ''),
                              onTap: () async {
                                try {
                                  final d = await app.api.call(
                                      'POST',
                                      '/api/conversations/direct',
                                      {'userId': u['_id']});
                                  if (!mounted) return;
                                  Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                          builder: (_) => Chat(
                                              conversation:
                                                  Map<String, dynamic>.from(
                                                      d['conversation']))));
                                } catch (error) {
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                            content: Text(error.toString())));
                                  }
                                }
                              },
                            );
                          })),
    ]);
  }

  Widget _memories() {
    if (memoriesLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (memoriesError != null) {
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(memoriesError!, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        FilledButton(onPressed: loadMemories, child: const Text('Retry'))
      ]));
    }
    if (memories.isEmpty) {
      return const Empty(
          icon: Icons.auto_awesome,
          title: 'No memories saved',
          subtitle: 'Save useful events, tasks, places and payments.');
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: memories.length,
      itemBuilder: (_, i) {
        final memory = Map<String, dynamic>.from(memories[i]);
        return Dismissible(
          key: ValueKey(memory['_id']),
          direction: DismissDirection.endToStart,
          background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              child: const Icon(Icons.delete_outline)),
          onDismissed: (_) async {
            try {
              await app.api.call('DELETE', '/api/memories/${memory['_id']}');
            } catch (_) {}
          },
          child: Card(
              child: ListTile(
                  title: Text(memory['title']?.toString() ?? 'Memory'),
                  subtitle: Text(memory['description']?.toString() ?? ''))),
        );
      },
    );
  }

  Future<void> _newGroup() async {
    final title = TextEditingController();
    final emails = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Create group'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Group name')),
            TextField(
                controller: emails,
                keyboardType: TextInputType.emailAddress,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                    labelText: 'Member emails',
                    helperText: 'Separate addresses with commas or new lines')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              try {
                final memberEmails = emails.text
                    .split(RegExp(r'[,;\n]'))
                    .map((value) => value.trim().toLowerCase())
                    .where((value) => value.isNotEmpty)
                    .toSet();
                if (memberEmails.isEmpty) {
                  throw Exception('Enter at least one member email');
                }
                final memberIds = <String>[];
                for (final memberEmail in memberEmails) {
                  final result = await app.api.call('GET',
                      '/api/users/search?q=${Uri.encodeQueryComponent(memberEmail)}');
                  final found = List<dynamic>.from(result['users'] ?? []);
                  final match = found.where((user) =>
                      user is Map &&
                      user['email']?.toString().toLowerCase() == memberEmail);
                  if (match.isEmpty) {
                    throw Exception('No account found for $memberEmail');
                  }
                  memberIds.add(match.first['_id'].toString());
                }
                final created =
                    await app.api.call('POST', '/api/conversations/group', {
                  'title': title.text.trim(),
                  'memberIds': memberIds,
                });
                if (dialog.mounted) Navigator.pop(dialog);
                if (!mounted) return;
                Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => Chat(
                          conversation: Map<String, dynamic>.from(
                              created['conversation'])),
                    ));
              } catch (error) {
                if (mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(error.toString())));
                }
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
    title.dispose();
    emails.dispose();
  }
}

class Empty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const Empty(
      {super.key,
      required this.icon,
      required this.title,
      required this.subtitle});
  @override
  Widget build(BuildContext context) {
    return Center(
        child: Padding(
      padding: const EdgeInsets.all(30),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 60),
        const SizedBox(height: 12),
        Text(title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Text(subtitle, textAlign: TextAlign.center),
      ]),
    ));
  }
}

class Chat extends StatefulWidget {
  final Map<String, dynamic> conversation;
  const Chat({super.key, required this.conversation});
  @override
  State<Chat> createState() => _ChatState();
}

class _ChatState extends State<Chat> {
  final input = TextEditingController();
  final searchInput = TextEditingController();
  List<dynamic> messages = [];
  String expiry = 'NONE';
  String? reply;
  String? typingUser;
  bool searching = false;
  bool sending = false;
  final Set<String> onlineIds = {};
  io.Socket? socket;
  bool loading = true;
  String? loadError;
  AppState get app => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    load();
    connect();
  }

  Future<void> load() async {
    try {
      final detail = await app.api
          .call('GET', '/api/conversations/${widget.conversation['_id']}');
      widget.conversation
          .addAll(Map<String, dynamic>.from(detail['conversation']));
      final result = await app.api.call(
          'GET', '/api/conversations/${widget.conversation['_id']}/messages');
      final fetched = List<dynamic>.from(result['messages'] ?? []);
      if (mounted) {
        setState(() => messages = mergeMessages(messages, fetched));
      }
      for (final item in fetched) {
        if (item is Map &&
            item['senderId']?.toString() != app.user?['id']?.toString()) {
          markReceived(item['_id'].toString());
        }
      }
    } catch (error) {
      loadError = error.toString();
    }
    if (mounted) setState(() => loading = false);
  }

  void connect() {
    socket = io.io(
      app.api.base,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': app.api.token})
          .disableAutoConnect()
          .build(),
    );
    socket!.connect();
    socket!.onConnect(
        (_) => socket!.emit('conversation:join', widget.conversation['_id']));
    socket!.on('typing:start', (data) {
      if (!mounted ||
          data is! Map ||
          data['userId']?.toString() == app.user?['id']?.toString()) {
        return;
      }
      setState(() => typingUser = data['userId']?.toString());
    });
    socket!.on('typing:stop', (_) {
      if (mounted) setState(() => typingUser = null);
    });
    socket!.on('user:online', (data) {
      if (data is Map && mounted) {
        setState(() => onlineIds.add(data['userId'].toString()));
      }
    });
    socket!.on('user:offline', (data) {
      if (data is Map && mounted) {
        setState(() => onlineIds.remove(data['userId'].toString()));
      }
    });
    socket!.on('message:new', (data) {
      if (!mounted || data is! Map) return;
      if (data['conversationId']?.toString() ==
          widget.conversation['_id']?.toString()) {
        final incoming = Map<String, dynamic>.from(data);
        final id = incoming['_id']?.toString();
        if (id == null ||
            !messages
                .any((item) => item is Map && item['_id']?.toString() == id)) {
          setState(() => messages.add(incoming));
        }
        if (id != null &&
            incoming['senderId']?.toString() != app.user?['id']?.toString()) {
          markReceived(id);
        }
      }
    });
    socket!.on('message:expired', (data) {
      if (!mounted || data is! Map) return;
      final index = messages.indexWhere((m) =>
          m is Map && m['_id']?.toString() == data['messageId']?.toString());
      if (index >= 0) {
        setState(() {
          final copy = Map<String, dynamic>.from(messages[index]);
          copy['expiredAt'] = DateTime.now().toIso8601String();
          copy['text'] = '';
          copy['mediaUrl'] = null;
          messages[index] = copy;
        });
      }
    });
    socket!.on(
        'message:delivered', (data) => updateMessageState(data, 'deliveredTo'));
    socket!.on('message:read', (data) => updateMessageState(data, 'readBy'));
  }

  void updateMessageState(dynamic data, String field) {
    if (!mounted || data is! Map) return;
    final index = messages.indexWhere((item) =>
        item is Map &&
        item['_id']?.toString() == data['messageId']?.toString());
    if (index < 0) return;
    setState(() {
      final updated = Map<String, dynamic>.from(messages[index]);
      final ids = List<dynamic>.from(updated[field] ?? []);
      if (!ids.any((id) => id.toString() == data['userId']?.toString())) {
        ids.add(data['userId']);
      }
      updated[field] = ids;
      messages[index] = updated;
    });
  }

  Future<void> markReceived(String id) async {
    try {
      await app.api.call('POST', '/api/messages/$id/delivered', {});
      await app.api.call('POST', '/api/messages/$id/read', {});
    } catch (_) {}
  }

  Future<void> send() async {
    final text = input.text.trim();
    if (text.isEmpty || sending) return;
    setState(() => sending = true);
    try {
      final result = await app.api.call(
          'POST', '/api/conversations/${widget.conversation['_id']}/messages', {
        'text': text,
        'expiryType': expiry,
        'expiresInSeconds': expiry == 'AFTER_TIME' ? 3600 : null,
        'replyTo': reply,
      });
      if (!mounted) return;
      final sent = Map<String, dynamic>.from(result['message']);
      final sentId = sent['_id']?.toString();
      setState(() {
        if (sentId == null ||
            !messages.any(
                (item) => item is Map && item['_id']?.toString() == sentId)) {
          messages.add(sent);
        }
        reply = null;
      });
      input.clear();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> searchMessages(String query) async {
    try {
      final result = await app.api.call('GET',
          '/api/conversations/${widget.conversation['_id']}/messages?q=${Uri.encodeQueryComponent(query)}');
      if (mounted) {
        setState(() => messages = List<dynamic>.from(result['messages'] ?? []));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> sendImageLink() async {
    final source = await showModalBottomSheet<String>(
        context: context,
        builder: (sheet) => SafeArea(
              child: Wrap(children: [
                ListTile(
                    leading: const Icon(Icons.photo_library_outlined),
                    title: const Text('Choose from device'),
                    onTap: () => Navigator.pop(sheet, 'device')),
                ListTile(
                    leading: const Icon(Icons.link),
                    title: const Text('Share secure image URL'),
                    onTap: () => Navigator.pop(sheet, 'url')),
              ]),
            ));
    if (!mounted || source == null) return;
    try {
      Map<String, dynamic> uploadRequest;
      if (source == 'url') {
        final url = TextEditingController();
        final accepted = await showDialog<bool>(
            context: context,
            builder: (dialog) => AlertDialog(
                    title: const Text('Share an image'),
                    content: TextField(
                        controller: url,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                            labelText: 'Secure image URL',
                            hintText: 'https://…')),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialog, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(dialog, true),
                          child: const Text('Share'))
                    ]));
        if (accepted != true) {
          url.dispose();
          return;
        }
        uploadRequest = {'url': url.text.trim()};
        url.dispose();
      } else {
        final file = await ImagePicker().pickImage(source: ImageSource.gallery);
        if (file == null) return;
        final bytes = await file.readAsBytes();
        if (bytes.length > 650 * 1024) {
          throw Exception('Choose an image smaller than 650 KB');
        }
        final name = file.name.toLowerCase();
        final mimeType = name.endsWith('.png')
            ? 'image/png'
            : (name.endsWith('.webp') ? 'image/webp' : 'image/jpeg');
        uploadRequest = {'data': base64Encode(bytes), 'mimeType': mimeType};
      }
      final uploaded = await app.api.call('POST', '/api/media', uploadRequest);
      final sent = await app.api.call(
          'POST', '/api/conversations/${widget.conversation['_id']}/messages', {
        'messageType': 'image',
        'mediaUrl': uploaded['mediaUrl'],
        'expiryType': expiry
      });
      if (mounted) {
        final message = Map<String, dynamic>.from(sent['message']);
        final id = message['_id']?.toString();
        setState(() {
          if (id == null ||
              !messages.any((item) =>
                  item is Map && item['_id']?.toString() == id)) {
            messages.add(message);
          }
        });
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> groupOptions() async {
    final members =
        List<dynamic>.from(widget.conversation['participants'] ?? []);
    final isAdmin = List<dynamic>.from(widget.conversation['admins'] ?? [])
        .any((id) => id.toString() == app.user?['id']?.toString());
    await showModalBottomSheet<void>(
        context: context,
        builder: (sheet) => SafeArea(
                child: Wrap(children: [
              Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                      widget.conversation['description']
                                  ?.toString()
                                  .isNotEmpty ==
                              true
                          ? widget.conversation['description'].toString()
                          : '${members.length} members',
                      style: Theme.of(context).textTheme.titleMedium)),
              if (isAdmin)
                ListTile(
                    leading: const Icon(Icons.person_add_alt_1),
                    title: const Text('Add member'),
                    onTap: () async {
                      final email = TextEditingController();
                      try {
                        final chosen = await showDialog<bool>(
                            context: context,
                            builder: (d) => AlertDialog(
                                    title: const Text('Add group member'),
                                    content: TextField(
                                        controller: email,
                                        keyboardType:
                                            TextInputType.emailAddress,
                                        decoration: const InputDecoration(
                                            labelText: 'Member email')),
                                    actions: [
                                      TextButton(
                                          onPressed: () =>
                                              Navigator.pop(d, false),
                                          child: const Text('Cancel')),
                                      FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(d, true),
                                          child: const Text('Add'))
                                    ]));
                        if (chosen != true) return;
                        final found = await app.api.call('GET',
                            '/api/users/search?q=${Uri.encodeQueryComponent(email.text.trim())}');
                        final users = List<dynamic>.from(found['users'] ?? []);
                        final emailValue = email.text.trim().toLowerCase();
                        final matches = users.where((user) =>
                            user is Map &&
                            user['email']?.toString().toLowerCase() ==
                                emailValue);
                        if (matches.isEmpty) {
                          throw Exception('No matching account found');
                        }
                        await app.api.call(
                            'POST',
                            '/api/conversations/${widget.conversation['_id']}/members',
                            {'userId': matches.first['_id']});
                        final d = await app.api.call('GET',
                            '/api/conversations/${widget.conversation['_id']}');
                        if (mounted) {
                          setState(() => widget.conversation.addAll(
                              Map<String, dynamic>.from(d['conversation'])));
                        }
                        if (sheet.mounted) Navigator.pop(sheet);
                      } catch (error) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(error.toString())));
                        }
                      } finally {
                        email.dispose();
                      }
                    }),
              ...members.map((raw) {
                final person = Map<String, dynamic>.from(raw);
                final id = (person['_id'] ?? person['id']).toString();
                final admin =
                    List<dynamic>.from(widget.conversation['admins'] ?? [])
                        .any((item) => item.toString() == id);
                return ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: Text(
                        '${person['name'] ?? 'Member'}${admin ? ' · admin' : ''}'),
                    subtitle: Text(person['email']?.toString() ?? ''),
                    trailing: isAdmin && id != app.user?['id']?.toString()
                        ? PopupMenuButton<String>(
                            onSelected: (action) async {
                              try {
                                if (action == 'remove') {
                                  await app.api.call('DELETE',
                                      '/api/conversations/${widget.conversation['_id']}/members/$id');
                                } else if (admin) {
                                  await app.api.call('DELETE',
                                      '/api/conversations/${widget.conversation['_id']}/admins/$id');
                                } else {
                                  await app.api.call(
                                      'POST',
                                      '/api/conversations/${widget.conversation['_id']}/admins/$id',
                                      {});
                                }
                                final d = await app.api.call('GET',
                                    '/api/conversations/${widget.conversation['_id']}');
                                if (mounted) {
                                  setState(() => widget.conversation.addAll(
                                      Map<String, dynamic>.from(
                                          d['conversation'])));
                                }
                              } catch (error) {
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                          content: Text(error.toString())));
                                }
                              }
                            },
                            itemBuilder: (_) => [
                                  PopupMenuItem(
                                      value: admin ? 'demote' : 'promote',
                                      child: Text(admin
                                          ? 'Remove admin'
                                          : 'Make admin')),
                                  const PopupMenuItem(
                                      value: 'remove',
                                      child: Text('Remove member'))
                                ])
                        : null);
              }),
              if (!isAdmin ||
                  List<dynamic>.from(widget.conversation['admins'] ?? [])
                          .length >
                      1)
                ListTile(
                    leading: const Icon(Icons.exit_to_app),
                    title: const Text('Leave group'),
                    onTap: () async {
                      try {
                        await app.api.call(
                            'POST',
                            '/api/conversations/${widget.conversation['_id']}/leave',
                            {});
                        if (mounted && sheet.mounted) {
                          Navigator.pop(sheet);
                          Navigator.pop(context);
                        }
                      } catch (error) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(error.toString())));
                        }
                      }
                    })
            ])));
  }

  Widget renderImage(String url) {
    if (url.startsWith('data:image/')) {
      try {
        return Image.memory(base64Decode(url.substring(url.indexOf(',') + 1)),
            width: 220);
      } catch (_) {
        return const Text('Image unavailable');
      }
    }
    return Image.network(url,
        width: 220,
        errorBuilder: (_, __, ___) => const Text('Image unavailable'));
  }

  @override
  void dispose() {
    socket?.dispose();
    input.dispose();
    searchInput.dispose();
    super.dispose();
  }

  Future<void> extractMemory() async {
    try {
      final eligibleSources = messages
          .whereType<Map>()
          .where((item) =>
              item['expiredAt'] == null &&
              item['messageType'] == 'text' &&
              item['text'] is String &&
              (item['text'] as String).trim().isNotEmpty)
          .toList();
      final source = input.text.trim().isNotEmpty || eligibleSources.isEmpty
          ? null
          : eligibleSources.last;
      final sourceText = input.text.trim().isNotEmpty
          ? input.text.trim()
          : source?['text']?.toString() ?? '';
      if (sourceText.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Send a message before extracting a memory.')));
        return;
      }
      final result = await app.api
          .call('POST', '/api/memories/extract', {'text': sourceText});
      final candidates = List<dynamic>.from(result['candidates'] ?? []);
      if (!mounted) return;
      if (candidates.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No memory candidate found.')));
        return;
      }
      final selected = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Save a memory'),
          content: SizedBox(
            width: 420,
            child: ListView(
              shrinkWrap: true,
              children: candidates.map((raw) {
                final item = Map<String, dynamic>.from(raw);
                return ListTile(
                  leading: const Icon(Icons.auto_awesome),
                  title: Text(item['title']?.toString() ?? 'Memory'),
                  subtitle: Text(item['description']?.toString() ?? ''),
                  onTap: () => Navigator.pop(dialog, item),
                );
              }).toList(),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('Cancel'))
          ],
        ),
      );
      if (selected == null) return;
      await app.api.call('POST', '/api/memories', {
        ...selected,
        'conversationId': widget.conversation['_id'],
        if (source != null && source['_id'] != null)
          'sourceMessageId': source['_id'],
      });
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Memory saved')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> reactTo(String messageId, String emoji) async {
    try {
      final result = await app.api
          .call('POST', '/api/messages/$messageId/reactions', {'emoji': emoji});
      final updated = Map<String, dynamic>.from(result['message']);
      final index = messages.indexWhere(
          (item) => item is Map && item['_id']?.toString() == messageId);
      if (index >= 0 && mounted) setState(() => messages[index] = updated);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> showMessageActions(Map<String, dynamic> message) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
                leading: const Icon(Icons.reply),
                title: const Text('Reply'),
                onTap: () => Navigator.pop(sheet, 'reply')),
            ListTile(
                leading: const Text('❤️', style: TextStyle(fontSize: 22)),
                title: const Text('React with ❤️'),
                onTap: () => Navigator.pop(sheet, '❤️')),
            ListTile(
                leading: const Text('👍', style: TextStyle(fontSize: 22)),
                title: const Text('React with 👍'),
                onTap: () => Navigator.pop(sheet, '👍')),
            ListTile(
                leading: const Text('😂', style: TextStyle(fontSize: 22)),
                title: const Text('React with 😂'),
                onTap: () => Navigator.pop(sheet, '😂')),
          ],
        ),
      ),
    );
    if (action == null) return;
    if (action == 'reply') {
      setState(() => reply = message['_id']?.toString());
    } else if (message['_id'] != null) {
      await reactTo(message['_id'].toString(), action);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.conversation['type'] == 'group'
        ? (widget.conversation['title'] ?? 'Group').toString()
        : 'Chat';
    return Scaffold(
      appBar: AppBar(
        title: searching
            ? TextField(
                controller: searchInput,
                autofocus: true,
                onChanged: searchMessages,
                decoration: const InputDecoration(
                    hintText: 'Search this chat', border: InputBorder.none))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                    Text(title),
                    if (widget.conversation['type'] == 'direct')
                      Text(onlineIds.isNotEmpty ? 'Online' : 'Offline',
                          style: Theme.of(context).textTheme.labelSmall)
                  ]),
        actions: [
          IconButton(
              onPressed: () {
                setState(() {
                  searching = !searching;
                  if (!searching) {
                    searchInput.clear();
                    load();
                  }
                });
              },
              tooltip: 'Search messages',
              icon: Icon(searching ? Icons.close : Icons.search)),
          if (widget.conversation['type'] == 'group')
            IconButton(
                onPressed: groupOptions,
                tooltip: 'Group details',
                icon: const Icon(Icons.group_outlined)),
          IconButton(
              onPressed: extractMemory,
              tooltip: 'Save memory',
              icon: const Icon(Icons.auto_awesome)),
        ],
      ),
      body: Column(children: [
        if (typingUser != null)
          const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Someone is typing…')),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : loadError != null
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(loadError!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: load, child: const Text('Retry'))
                    ]))
                  : messages.isEmpty
                      ? const Empty(
                          icon: Icons.chat_bubble_outline,
                          title: 'Start the conversation',
                          subtitle: 'Send the first message.')
                      : ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: messages.length,
                          itemBuilder: (_, i) {
                            final message =
                                Map<String, dynamic>.from(messages[i]);
                            final mine = message['senderId']?.toString() ==
                                app.user?['id']?.toString();
                            final text = message['expiredAt'] != null
                                ? 'This message has expired.'
                                : (message['text'] ?? '[media]').toString();
                            return GestureDetector(
                              onLongPress: () => showMessageActions(message),
                              child: Align(
                                alignment: mine
                                    ? Alignment.centerRight
                                    : Alignment.centerLeft,
                                child: Container(
                                  constraints:
                                      const BoxConstraints(maxWidth: 330),
                                  margin: const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: mine
                                        ? Theme.of(context)
                                            .colorScheme
                                            .primaryContainer
                                        : Colors.white,
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (message['expiredAt'] == null &&
                                            message['messageType'] == 'image' &&
                                            message['mediaUrl'] != null)
                                          renderImage(
                                              message['mediaUrl'].toString())
                                        else
                                          Text(text),
                                        if (message['reactions'] is List &&
                                            (message['reactions'] as List)
                                                .isNotEmpty)
                                          Text((message['reactions'] as List)
                                              .map((r) => r['emoji'])
                                              .join(' ')),
                                        if (mine &&
                                            message['deliveredTo'] is List &&
                                            (message['deliveredTo'] as List)
                                                    .length >
                                                1)
                                          Text(
                                              message['readBy'] is List &&
                                                      (message['readBy']
                                                                  as List)
                                                              .length >
                                                          1
                                                  ? 'Read'
                                                  : 'Delivered',
                                              style:
                                                  const TextStyle(fontSize: 10))
                                      ]),
                                ),
                              ),
                            );
                          },
                        ),
        ),
        if (reply != null)
          const Padding(
              padding: EdgeInsets.all(6),
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Replying to a message'))),
        SafeArea(
            child: Row(children: [
          IconButton(
              onPressed: sendImageLink,
              tooltip: 'Share image URL',
              icon: const Icon(Icons.image_outlined)),
          PopupMenuButton<String>(
            onSelected: (value) => setState(() => expiry = value),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'NONE', child: Text('Permanent')),
              PopupMenuItem(value: 'AFTER_READ', child: Text('After read')),
              PopupMenuItem(value: 'AFTER_TIME', child: Text('After 1 hour')),
              PopupMenuItem(value: 'AFTER_REPLY', child: Text('After reply')),
            ],
          ),
          Expanded(
              child: TextField(
                  controller: input,
                  minLines: 1,
                  maxLines: 5,
                  onChanged: (value) {
                    final id = widget.conversation['_id'];
                    if (value.isEmpty) {
                      socket?.emit('typing:stop', id);
                    } else {
                      socket?.emit('typing:start', id);
                    }
                  },
                  decoration: const InputDecoration(
                      hintText: 'Write a message…', border: InputBorder.none))),
          IconButton(
              onPressed: sending ? null : send,
              icon: sending
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send)),
        ])),
      ]),
    );
  }
}

class Profile extends StatefulWidget {
  const Profile({super.key});
  @override
  State<Profile> createState() => _ProfileState();
}

class _ProfileState extends State<Profile> {
  late TextEditingController name, phone;
  bool lastSeen = true,
      receipts = true,
      messages = true,
      mentions = true,
      memories = true;
  @override
  void initState() {
    super.initState();
    final u = context.read<AppState>().user ?? {};
    name = TextEditingController(text: u['name']?.toString() ?? '');
    phone = TextEditingController(text: u['phone']?.toString() ?? '');
    final p = Map<String, dynamic>.from(u['privacy'] ?? {}),
        n = Map<String, dynamic>.from(u['notificationPreferences'] ?? {});
    lastSeen = p['lastSeen'] ?? true;
    receipts = p['readReceipts'] ?? true;
    messages = n['messages'] ?? true;
    mentions = n['mentions'] ?? true;
    memories = n['memories'] ?? true;
  }

  @override
  void dispose() {
    name.dispose();
    phone.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final api = context.read<AppState>().api;
    try {
      final d = await api.call('PATCH', '/api/users/me', {
        'name': name.text.trim(),
        'phone': phone.text.trim(),
        'privacy': {'lastSeen': lastSeen, 'readReceipts': receipts},
        'notificationPreferences': {
          'messages': messages,
          'mentions': mentions,
          'memories': memories
        },
      });
      if (!mounted) return;
      context.read<AppState>().user = Map<String, dynamic>.from(d['user']);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Profile saved')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> changePassword() async {
    final current = TextEditingController();
    final next = TextEditingController();
    try {
      await showDialog<void>(
          context: context,
          builder: (d) => AlertDialog(
                  title: const Text('Change password'),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: current,
                        obscureText: true,
                        decoration: const InputDecoration(
                            labelText: 'Current password')),
                    TextField(
                        controller: next,
                        obscureText: true,
                        decoration: const InputDecoration(
                            labelText: 'New password (8+ characters)'))
                  ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(d),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () async {
                          try {
                            await context.read<AppState>().api.call(
                                'POST', '/api/auth/change-password', {
                              'currentPassword': current.text,
                              'newPassword': next.text
                            });
                            if (d.mounted) Navigator.pop(d);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('Password changed')));
                            }
                          } catch (error) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(error.toString())));
                            }
                          }
                        },
                        child: const Text('Update'))
                  ]));
    } finally {
      current.dispose();
      next.dispose();
    }
  }

  @override
  Widget build(BuildContext context) =>
      ListView(padding: const EdgeInsets.all(18), children: [
        TextField(
            controller: name,
            decoration: const InputDecoration(
                labelText: 'Name', border: OutlineInputBorder())),
        const SizedBox(height: 12),
        TextField(
            controller: phone,
            decoration: const InputDecoration(
                labelText: 'Phone', border: OutlineInputBorder())),
        const SizedBox(height: 18),
        const Text('Privacy',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        SwitchListTile(
            value: lastSeen,
            onChanged: (v) => setState(() => lastSeen = v),
            title: const Text('Show last seen')),
        SwitchListTile(
            value: receipts,
            onChanged: (v) => setState(() => receipts = v),
            title: const Text('Read receipts')),
        const Text('Notifications',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        SwitchListTile(
            value: messages,
            onChanged: (v) => setState(() => messages = v),
            title: const Text('New messages')),
        SwitchListTile(
            value: mentions,
            onChanged: (v) => setState(() => mentions = v),
            title: const Text('Mentions')),
        SwitchListTile(
            value: memories,
            onChanged: (v) => setState(() => memories = v),
            title: const Text('Memory suggestions')),
        FilledButton(onPressed: save, child: const Text('Save changes')),
        TextButton(
            onPressed: changePassword, child: const Text('Change password')),
        TextButton(
            onPressed: () => context.read<AppState>().logout(),
            child: const Text('Sign out'))
      ]);
}
