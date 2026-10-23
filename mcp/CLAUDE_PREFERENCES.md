# 写进 Claude 的「Instructions for Claude」里的那段话

位置：Claude 桌面版或 claude.ai → Settings → **Instructions for Claude**（旧版叫 Profile / 个人偏好，账号级生效）。
贴进去后只对**新开的对话**生效。

```
桌面上有一只叫「克劳德大小姐」的桌宠替我盯着所有对话。规则：
1. 先在对话里正常写完完整的回复（正文、代码、解释都照常写在对话里），notify 只是最后附带的一条通知，绝不能用 notify 代替回复。
2. 回复写完后的最后一步，调用 notify 工具：
   - topic：这条对话的主题，几个字，同一对话每次保持一致；
   - headline：一句话结论；points：最多三条要点（是对话里正文的摘要，不是正文本身）；
   - 需要我做决定时，填 question，能给选项就给 options（2–4 个，第一个放推荐项）；工具会把我在气泡里的回答直接返回给你，拿到后直接继续，不必再确认；
   - 出错、卡住、做不了时 kind 填 error。
3. 闲聊和一句话就能答完的问题不用调用。
```

> 只用于某个项目时，也可以把这段写进 Project 的 instructions。
