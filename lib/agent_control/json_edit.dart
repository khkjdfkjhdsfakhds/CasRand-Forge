import 'dart:convert';

/// Errors raised while reading or editing a JSON document by pointer.
class JsonEditException implements Exception {
  final String message;

  const JsonEditException(this.message);

  @override
  String toString() => message;
}

/// Returns a mutable deep copy made only of maps, lists and scalars.
dynamic deepCopyJson(dynamic value) => json.decode(json.encode(value));

/// Splits an RFC 6901 JSON Pointer. A missing leading slash is tolerated so
/// agents can write `prompt_config/prompts/0` as well as `/prompt_config/...`.
List<String> parseJsonPointer(String pointer) {
  final trimmed = pointer.trim();
  if (trimmed.isEmpty || trimmed == '/') return const [];
  final body = trimmed.startsWith('/') ? trimmed.substring(1) : trimmed;
  return body
      .split('/')
      .map((token) => token.replaceAll('~1', '/').replaceAll('~0', '~'))
      .toList(growable: false);
}

String encodeJsonPointer(List<Object> segments) {
  if (segments.isEmpty) return '';
  return segments
      .map((segment) =>
          '/${segment.toString().replaceAll('~', '~0').replaceAll('/', '~1')}')
      .join();
}

int _listIndex(List<dynamic> list, String token, String pointer,
    {bool allowEnd = false}) {
  final index = int.tryParse(token);
  final limit = allowEnd ? list.length : list.length - 1;
  if (index == null || index < 0 || index > limit) {
    throw JsonEditException(
      "Index '$token' is out of range in '$pointer' (length ${list.length}).",
    );
  }
  return index;
}

dynamic _child(dynamic node, String token, String pointer) {
  if (node is Map) {
    if (!node.containsKey(token)) {
      throw JsonEditException("Key '$token' does not exist in '$pointer'.");
    }
    return node[token];
  }
  if (node is List) return node[_listIndex(node, token, pointer)];
  throw JsonEditException("'$pointer' passes through a non-container value.");
}

/// Reads the value at [pointer]; throws when any segment does not exist.
dynamic getAtJsonPointer(dynamic root, String pointer) {
  var node = root;
  for (final token in parseJsonPointer(pointer)) {
    node = _child(node, token, pointer);
  }
  return node;
}

/// Replaces (or adds) the value at [pointer]. For lists, an existing index is
/// replaced and `-` appends. The root itself cannot be replaced here.
void setAtJsonPointer(dynamic root, String pointer, dynamic value) {
  final tokens = parseJsonPointer(pointer);
  if (tokens.isEmpty) {
    throw const JsonEditException('The document root cannot be replaced.');
  }
  var parent = root;
  for (final token in tokens.take(tokens.length - 1)) {
    parent = _child(parent, token, pointer);
  }
  final last = tokens.last;
  if (parent is Map) {
    parent[last] = value;
  } else if (parent is List) {
    if (last == '-') {
      parent.add(value);
    } else {
      parent[_listIndex(parent, last, pointer)] = value;
    }
  } else {
    throw JsonEditException("'$pointer' passes through a non-container value.");
  }
}

/// Removes the value at [pointer]; list items after it shift down.
void removeAtJsonPointer(dynamic root, String pointer) {
  final tokens = parseJsonPointer(pointer);
  if (tokens.isEmpty) {
    throw const JsonEditException('The document root cannot be removed.');
  }
  var parent = root;
  for (final token in tokens.take(tokens.length - 1)) {
    parent = _child(parent, token, pointer);
  }
  final last = tokens.last;
  if (parent is Map) {
    if (!parent.containsKey(last)) {
      throw JsonEditException("Key '$last' does not exist in '$pointer'.");
    }
    parent.remove(last);
  } else if (parent is List) {
    parent.removeAt(_listIndex(parent, last, pointer));
  } else {
    throw JsonEditException("'$pointer' passes through a non-container value.");
  }
}

/// Applies an RFC 7386 JSON Merge Patch and returns the merged value.
dynamic applyJsonMergePatch(dynamic target, dynamic patch) {
  if (patch is! Map) return deepCopyJson(patch);
  final result =
      target is Map ? Map<String, dynamic>.from(target) : <String, dynamic>{};
  patch.forEach((key, value) {
    final name = key.toString();
    if (value == null) {
      result.remove(name);
    } else {
      result[name] = applyJsonMergePatch(result[name], value);
    }
  });
  return result;
}

/// One pointer edit: `{"op": "set" | "remove", "path": "...", "value": ...}`.
void applyJsonOperations(dynamic root, List<dynamic> operations) {
  for (var index = 0; index < operations.length; index++) {
    final operation = operations[index];
    if (operation is! Map) {
      throw JsonEditException('operations[$index] must be an object.');
    }
    final op = (operation['op'] ?? 'set').toString();
    final path = operation['path'];
    if (path is! String) {
      throw JsonEditException('operations[$index].path must be a string.');
    }
    switch (op) {
      case 'set':
      case 'replace':
      case 'add':
        if (!operation.containsKey('value')) {
          throw JsonEditException('operations[$index] is missing "value".');
        }
        setAtJsonPointer(root, path, deepCopyJson(operation['value']));
      case 'remove':
        removeAtJsonPointer(root, path);
      default:
        throw JsonEditException(
          "operations[$index].op '$op' is not supported; use set or remove.",
        );
    }
  }
}
