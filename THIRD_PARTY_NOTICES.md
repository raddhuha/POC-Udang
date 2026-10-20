# Third-party source attribution

`POC Udang/Services/NativeBoTSORT.swift` adapts the no-ReID BoT-SORT association, lifecycle and XYWH Kalman algorithms from Ultralytics 8.4.177:

- https://github.com/ultralytics/ultralytics/blob/v8.4.177/ultralytics/trackers/bot_sort.py
- https://github.com/ultralytics/ultralytics/blob/v8.4.177/ultralytics/trackers/byte_tracker.py
- https://github.com/ultralytics/ultralytics/blob/v8.4.177/ultralytics/trackers/utils/kalman_filter.py
- https://github.com/ultralytics/ultralytics/blob/v8.4.177/ultralytics/trackers/utils/stracks.py

Upstream copyright: Ultralytics. Upstream license: GNU Affero General Public License, version 3.0 (AGPL-3.0), https://github.com/ultralytics/ultralytics/blob/v8.4.177/LICENSE.

The complete upstream license text is included in `LICENSES/Ultralytics-AGPL-3.0.txt`.

The Swift port replaces the full Kalman matrix with equivalent independent XYWH position/velocity blocks for translation-only GMC, implements cost-limited Hungarian assignment, and uses Apple Vision translation registration instead of OpenCV sparse optical flow. It is not the official Ultralytics Python runtime or an official Ultralytics Swift BoT-SORT package.

The bundled YOLO26 Core ML model also contains Ultralytics author/license metadata. No model has been retrained or downloaded by the application.
