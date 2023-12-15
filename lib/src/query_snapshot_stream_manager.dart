import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collection/collection.dart';
import 'package:rxdart/rxdart.dart';

import 'fake_query_with_parent.dart';
import 'mock_document_change.dart';
import 'mock_query_snapshot.dart';

/// This class maintains stream controllers for Queries to fire snapshots.
class QuerySnapshotStreamManager {
  static QuerySnapshotStreamManager? _instance;

  factory QuerySnapshotStreamManager() =>
      _instance ??= QuerySnapshotStreamManager._internal();

  QuerySnapshotStreamManager._internal();
  final Map<
          FirebaseFirestore,
          Map<String,
              Map<FakeQueryWithParent, StreamController<QuerySnapshot>>>>
      _streamCache = {};

  final Map<FakeQueryWithParent, QuerySnapshot> _cacheQuerySnapshot = {};

  Future<void> clear() {
    final futures = <Future>[];
    final streamControllers = List.of(_streamCache.values
        .map((e) => e.values)
        .flattened
        .map((e) => e.values)
        .flattened);
    _streamCache.clear();
    for (final streamController in streamControllers) {
      futures.add(streamController.close());
    }
    return Future.wait(futures);
  }

  /// Recursively finds the base collection path.
  String _getBaseCollectionPath(FakeQueryWithParent query) {
    if (query is CollectionReference) {
      return (query as CollectionReference).path;
    } else {
      // In theory retrieveParentPath should stop at the collection reference.
      // So _parentQuery can never be null.
      return _getBaseCollectionPath(query.parentQuery!);
    }
  }

  void register<T>(FakeQueryWithParent query) {
    final firestore = query.firestore;
    if (!_streamCache.containsKey(query.firestore)) {
      _streamCache[firestore] = {};
    }
    final path = _getBaseCollectionPath(query);
    if (!_streamCache[firestore]!.containsKey(path)) {
      _streamCache[query.firestore]![path] = {};
    }
    _streamCache[firestore]![path]!
        .putIfAbsent(query, () => BehaviorSubject<QuerySnapshot<T>>());
  }

  void unregister(FakeQueryWithParent query) {
    final path = _getBaseCollectionPath(query);
    final pathCache = _streamCache[query.firestore]![path];
    if (pathCache == null) {
      return;
    }
    final controller = pathCache.remove(query);
    controller!.close();
  }

  StreamController<QuerySnapshot<T>> getStreamController<T>(
      FakeQueryWithParent query) {
    final path = _getBaseCollectionPath(query);
    final pathCache = _streamCache[query.firestore]![path];
    // Before calling `getStreamController(query)`, one should have called
    // `register(query)` beforehand, so pathCache should never be null.
    assert(pathCache != null);
    final streamController = pathCache![query]!;
    if (streamController is! StreamController<QuerySnapshot<T>>) {
      throw UnimplementedError();
    }
    return streamController;
  }

  Future<void> fireSnapshotUpdate<T>(
    FirebaseFirestore firestore,
    String path, {
    String? id,
  }) async {
    if (!_streamCache.containsKey(firestore)) {
      // Normal. It happens if you try to fire updates before anyone has
      // subscribed to snapshots.
      return;
    }
    final exactPathCache = _streamCache[firestore]![path];
    if (exactPathCache != null && id != null) {
      for (final query in [...exactPathCache.keys]) {
        if (query is! FakeQueryWithParent<T>) {
          continue;
        }

        final invalidCache = _cacheQuerySnapshot[query] != null && _cacheQuerySnapshot[query] is! QuerySnapshot<T>;
        if (invalidCache) {
          assert(invalidCache, 'querySnapshotPrior is not null or QuerySnapshot<T>. Got ${_cacheQuerySnapshot[query]}');
          continue;
        }
        final querySnapshotPrior = _cacheQuerySnapshot[query] as QuerySnapshot<T>?;

        final querySnapshot = await query.get();
        _cacheQuerySnapshot[query] = querySnapshot;
        final _docsPrior = querySnapshotPrior?.docs ?? [];
        final _docsCurrent = List.of(querySnapshot.docs);

        final _docChange = _getDocumentChange<T>(
          id: id,
          docsPrior: _docsPrior,
          docsCurrent: _docsCurrent,
        );

        if (_docChange != null) {
          final _querySnapshot = MockQuerySnapshot<T>(
            _docsCurrent,
            false,
            documentChanges: [_docChange],
          );
          exactPathCache[query]?.add(_querySnapshot);
        }
      }
    }

    // When a document is modified, fire an update on the parent collection.
    if (path.contains('/')) {
      final tokens = path.split('/');
      final parentPath = tokens.sublist(0, tokens.length - 1).join('/');
      final _id = id ?? tokens.last;
      await fireSnapshotUpdate<T>(firestore, parentPath, id: _id);
    }
  }

  /// Returns [DocumentChange] for doc [id] based on the change between [docsPrior] and [docsCurrent].
  DocumentChange<T>? _getDocumentChange<T>({
    required String id,
    required List<QueryDocumentSnapshot<T>> docsPrior,
    required List<QueryDocumentSnapshot<T>> docsCurrent,
  }) {
    final _docPriorIndex = docsPrior.indexWhere((element) {
      return element.id == id;
    });
    QueryDocumentSnapshot<T>? _docPrior;
    if (_docPriorIndex != -1) {
      _docPrior = docsPrior[_docPriorIndex];
    }

    final _docCurrentIndex = docsCurrent.indexWhere((element) {
      return element.id == id;
    });

    if (_docCurrentIndex != -1 && _docPriorIndex != -1) {
      /// Document is modified.
      return MockDocumentChange<T>(
        docsCurrent[_docCurrentIndex],
        DocumentChangeType.modified,
        oldIndex: _docPriorIndex,
        newIndex: _docCurrentIndex,
      );
    } else if (_docCurrentIndex != -1 && _docPriorIndex == -1) {
      /// Document is added.
      return MockDocumentChange<T>(
        docsCurrent[_docCurrentIndex],
        DocumentChangeType.added,
        oldIndex: -1,
        newIndex: _docCurrentIndex,
      );
    } else if (_docCurrentIndex == -1 && _docPriorIndex != -1) {
      /// Document is removed.
      return MockDocumentChange<T>(
        _docPrior!,
        DocumentChangeType.removed,
        oldIndex: _docPriorIndex,
        newIndex: -1,
      );
    }
    return null;
  }
}
