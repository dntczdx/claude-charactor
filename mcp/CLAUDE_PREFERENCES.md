# 写进 Claude 桌面版「设置 → 个人偏好」的那段话

把下面这段复制到 Claude 桌面版：**设置 → 个人资料 → 个人偏好**（"What personal preferences should Claude consider in responses?"）。
这样每条对话都会在回复结束时调用 `notify`，大小姐才知道该弹什么。

```
桌面上有一只叫「克劳德大小姐」的桌宠替我盯着所有对话。每轮回复写完后的最后一步，调用 notify 工具：
- topic：这条对话的主题，几个字，同一对话每次保持一致；
- headline：一句话结论；points：最多三条要点；
- 需要我做决定时，填 question，能给选项就给 options（2–4 个，第一个放推荐项）；工具会把我在气泡里的回答直接返回给你，拿到后直接继续，不必再确认；
- 出错、卡住、做不了时 kind 填 error。
闲聊和一句话就能答完的问题不用调用。
```

> 只用于某个项目时，也可以把这段写进 Project 的 instructions。
