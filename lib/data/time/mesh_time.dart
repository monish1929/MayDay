// lib/data/time/mesh_time.dart

import '../models/logical_clock.dart';

/// Handles the mesh time gossip estimates.
/// In MayDay, devices do not trust their own or other devices' wall clocks.
/// Instead, they maintain a running estimate of "mesh time" through gossip.
class MeshTimeGossip {
  /// The local device's estimate of the current offset between logical clock ticks
  /// and an agreed "mesh time" epoch, in milliseconds.
  /// This is updated via time gossip when devices meet.
  int _estimatedOffsetMs = 0;

  /// Updates the time gossip estimate when receiving a clock reading from another device.
  /// Volunteer nodes' clocks should be weighted higher in a real implementation.
  void receiveGossip(LogicalClock receivedClock, int remoteEstimate, bool isVolunteer) {
    // In a real implementation, this would use a Kalman filter or median of medians
    // to update the local estimate safely.
    // For now, we apply a simplistic adjustment towards the volunteer's estimate.
    if (isVolunteer) {
      // Weight volunteer's estimate heavily
      _estimatedOffsetMs = ((_estimatedOffsetMs + remoteEstimate * 3) / 4).round();
    } else {
      // Simple averaging
      _estimatedOffsetMs = ((_estimatedOffsetMs + remoteEstimate) / 2).round();
    }
  }

  /// Converts a logical clock value to an estimated display time.
  /// This is used purely for UI rendering ("about 2 hours ago").
  /// It should NEVER be used for ordering, merging, or decay logic.
  DateTime estimateDisplayTime(LogicalClock clock) {
    throw UnimplementedError('Stub - do not bind UI to this yet. Needs robust logical to real-time mapping.');
  }

  /// Format an estimated time as a relative string (e.g. "about 2 hours ago").
  String formatRelativeTime(DateTime estimatedTime, {DateTime? nowOverride}) {
    final now = nowOverride ?? DateTime.now(); // Wall clock is only used locally for UI relative diff
    final diff = now.difference(estimatedTime);

    if (diff.inMinutes < 1) {
      return 'just now';
    } else if (diff.inHours < 1) {
      return 'about ${diff.inMinutes} minutes ago';
    } else if (diff.inDays < 1) {
      return 'about ${diff.inHours} hours ago';
    } else {
      return 'about ${diff.inDays} days ago';
    }
  }
}
