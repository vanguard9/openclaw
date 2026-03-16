# Bug Investigations

> 记录 Bug 调查过程、根因和修复方案，避免重复排查。

<!-- 示例:
### 2026-02-28
- **现象**: 列表页滚动时偶发白屏
- **根因**: ListView 未设置 key，导致 Widget 复用错位
- **修复**: 为每个 item 添加 ValueKey(item.id)
- **相关文件**: `lib/features/list/list_page.dart`
-->
