# Prompt 编写指南

## 好的 Prompt 结构

```
[任务描述 — 要构建什么]

[技术栈]

[质量要求]
- 运行并验证输出
- 编写测试，全部通过
- 处理错误和边界情况

[项目结构（可选）]
```

## 示例：好的 Prompt

```
构建一个 GitHub Trending CLI 工具：

技术栈：Python 3.10+, requests, beautifulsoup4, Click

功能：
1. 抓取 GitHub Trending 页面
2. 按语言过滤 (--language python)
3. 按时间范围过滤 (--since daily/weekly/monthly)
4. 输出 JSON 和 Table 两种格式

质量要求：
1. 运行 demo 验证输出
2. pytest 测试 (>=5 个测试用例)
3. 网络请求添加超时和重试
4. 优雅处理解析失败

项目结构：
├── gh_trending/
│   ├── cli.py
│   ├── scraper.py
│   └── formatter.py
├── tests/
│   └── test_scraper.py
├── requirements.txt
└── README.md
```

## 示例：差的 Prompt

```
# 太模糊
写个爬虫

# 没有质量要求
写个 API

# 没有技术栈
做个 TODO 应用
```

## 进阶技巧

### 强制测试覆盖

```
测试要求：
- 覆盖率 >= 80%
- 正常路径 + 错误路径
- Mock 所有外部依赖
```

### 强制代码规范

```
代码标准：
- 所有函数有 docstring
- 使用类型标注
- ruff check 零 lint 错误
```

### 强制特定架构

```
架构要求：
- 分层设计 (controller / service / repository)
- 依赖注入
- 通过环境变量进行配置
```

## Token 效率建议

- **具体描述需求** — 模糊的 prompt 浪费探索 token
- **包含项目结构** — 减少规划开销
- **指定技术栈** — 避免框架选择纠结
- **设定明确的"完成"标准** — 防止过度工程化
