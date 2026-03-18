## `await` 关键字详解

### 1. 基本定义

`await` 是 Python 3.5+ 引入的关键字，用于**等待一个异步操作完成**并获取其结果。

```python
async def main():
    result = await some_async_function()
    print(result)
```

---

### 2. `await` 只能用在 `async` 函数中

```python
# ✅ 正确：async 函数中可以使用 await
async def foo():
    result = await bar()

# ❌ 错误：普通函数中不能使用 await
def foo():
    result = await bar()  # SyntaxError
```

---

### 3. 什么可以被 `await`？

#### 3.1 协程对象（Coroutine）

```python
import asyncio

async def say_hello():
    return "Hello!"

async def main():
    # 调用 async 函数返回的是协程对象
    coro = say_hello()
    print(type(coro))  # <class 'coroutine'>
    
    # await 等待协程完成并获取结果
    result = await coro
    print(result)  # "Hello!"

asyncio.run(main())
```

#### 3.2 Task（任务）

```python
import asyncio

async def task_function():
    await asyncio.sleep(1)
    return "Task done!"

async def main():
    # 创建 Task
    task = asyncio.create_task(task_function())
    
    # await Task
    result = await task
    print(result)  # "Task done!"

asyncio.run(main())
```

#### 3.3 Future / Promise

```python
import asyncio

async def main():
    # asyncio.Future 是一个"占位符"，表示一个尚未完成的值
    loop = asyncio.get_event_loop()
    future = loop.create_future()
    
    # 模拟异步操作完成
    loop.call_soon(lambda: future.set_result("Completed!"))
    
    # await Future
    result = await future
    print(result)  # "Completed!"

asyncio.run(main())
```

---

### 4. `await` 的执行流程

```python
import asyncio
import time

async def fetch_data():
    print("1. 开始获取数据...")
    await asyncio.sleep(2)  # 模拟耗时操作
    print("3. 数据获取完成!")
    return {"data": "hello"}

async def process_data():
    print("2. 开始处理数据...")
    await asyncio.sleep(1)
    print("4. 数据处理完成!")

async def main():
    start = time.time()
    
    # 顺序执行
    # result = await fetch_data()
    # await process_data()
    
    # 并发执行
    await asyncio.gather(
        fetch_data(),
        process_data()
    )
    
    print(f"总耗时: {time.time() - start:.2f}s")

asyncio.run(main())
```

**输出**：
```
1. 开始获取数据...
2. 开始处理数据...
4. 数据处理完成!
3. 数据获取完成!
总耗时: 2.00s
```

---

### 5. `await` 的内部机制

```python
# await 的伪代码实现原理
class Awaitable:
    def __await__(self):
        # 1. 将当前协程加入等待队列
        # 2. 让出控制权给事件循环
        # 3. 当操作完成时，恢复当前协程
        yield from self._wait_for_completion()
        return self._result
```

**实际执行过程**：
```
┌─────────────────────────────────────────────────────────────┐
│                    事件循环 (Event Loop)                      │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  协程A: await future ──────┐                               │
│                            ↓                               │
│                    [暂停/等待状态]                            │
│                            ↑                               │
│  协程B: await sleep ───────┘ (同时等待)                     │
│                            ↑                               │
│  协程C: await task ────────┘                               │
│                                                             │
│  当任意一个完成时 ──► 事件循环调度 ──► 恢复对应协程           │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

### 6. 常见错误处理

#### 6.1 捕获异常

```python
import asyncio

async def risky_operation():
    await asyncio.sleep(1)
    raise ValueError("出错了!")

async def main():
    try:
        result = await risky_operation()
    except ValueError as e:
        print(f"捕获异常: {e}")

asyncio.run(main())
```

#### 6.2 使用 try/finally 确保清理

```python
async def main():
    try:
        await some_operation()
    finally:
        # 无论成功还是失败，都会执行清理
        await cleanup()
```

---

### 7. `await` vs `return`

```python
# async 函数返回协程
async def get_data():
    return await fetch()  # 等价于: return fetch()

# 两者在效果上是一样的，但风格不同
async def version1():
    result = await fetch()
    return result

async def version2():
    return await fetch()  # 更简洁
```

---

### 8. 并发 vs 串行

```python
import asyncio
import time

async def task(name, duration):
    print(f"{name} 开始")
    await asyncio.sleep(duration)
    print(f"{name} 完成")
    return f"{name}_result"

async def serial():
    """串行执行：总耗时 = sum(所有任务耗时)"""
    result1 = await task("A", 2)
    result2 = await task("B", 2)
    return [result1, result2]

async def concurrent():
    """并发执行：总耗时 = max(所有任务耗时)"""
    results = await asyncio.gather(
        task("A", 2),
        task("B", 2),
    )
    return results

async def main():
    # 串行
    start = time.time()
    await serial()
    print(f"串行耗时: {time.time() - start:.2f}s")
    
    # 并发
    start = time.time()
    await concurrent()
    print(f"并发耗时: {time.time() - start:.2f}s")

asyncio.run(main())
```

**输出**：
```
A 开始
A 完成
B 开始
B 完成
串行耗时: 4.00s
A 开始
B 开始
B 完成
A 完成
并发耗时: 2.00s
```

---

### 9. 总结

| 特性 | 说明 |
|------|------|
| **作用** | 等待异步操作完成并获取结果 |
| **使用场景** | `async` 函数内部 |
| **可等待对象** | 协程、Task、Future |
| **执行机制** | 让出控制权给 B → 等待 A 完成 → 恢复执行 A |
| **并发方式** | `asyncio.gather()` 多个 `await` |

`await` 是异步编程的核心，它让"等待"变得高效，使单个线程可以同时处理多个并发任务！