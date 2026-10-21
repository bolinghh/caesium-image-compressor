# Native macOS workbench

Approved direction: a compact batch workbench using system components. Preserve the existing workflow and avoid adding a project system or navigation sidebar.

- Main table, right-hand parameter inspector, adjustable original/result comparison, bottom progress/status strip.
- System typography and semantic colors, native selection and focus, SF Symbols, thin separators. The system owns toolbar materials; image content stays opaque. No decorative glass, gradients, cards or shadows.
- `NativeDesign` in `UI/BatchView.swift` owns shared layout constants. Inspector minimum: 300 points; below 760 points, open it explicitly as a popover. Window minimum: 600 × 480; initial content: 1120 × 780.
- Parameters apply to the batch. Selection controls preview/removal. Compress runs the whole batch; failed-only retry is separate.
- Keep menu, keyboard, context-menu, drag/drop and Finder workflows. Text-field editing commands use the responder chain.
- Status uses text plus symbols. Cancel means draining active work; it cannot interrupt an encoding call.
- Settings and auxiliary tasks use native windows, sheets and alerts. Respect system/explicit appearance, RTL and accessibility settings.
- Mock fixtures in `UI/MockBatch.swift` do not start services or write settings. Actual screenshot acceptance uses `NativeUiTests`, not compilation alone.
