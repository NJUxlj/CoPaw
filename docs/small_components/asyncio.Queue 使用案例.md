## asyncio.Queue 使用案例

`asyncio.Queue` 是 Python 异步编程中用于生产者和消费者之间传递数据的线程安全队列。以下是几个常见的使用案例：

### 1. **生产者-消费者模式**

```python
import asyncio

async def producer(queue: asyncio.Queue):
    for i in range(5):
        await asyncio.sleep(1)
        await queue.put(f"item_{i}")
    await queue.put(None)  # 发送结束信号

async def consumer(queue: asyncio.Queue):
    while True:
        item = await queue.get()
        if item is None:
            break
        print(f"处理: {item}")
        queue.task_done()

async def main():
    queue = asyncio.Queue()
    await asyncio.gather(producer(queue), consumer(queue))

asyncio.run(main())
```

### 2. **任务分发**

```python
async def worker(worker_id: int, queue: asyncio.Queue):
    while True:
        task = await queue.get()
        print(f"Worker {worker_id} 处理任务: {task}")
        queue.task_done()

async def main():
    queue = asyncio.Queue()
    workers = [asyncio.create_task(worker(i, queue)) for i in range(3)]
    
    for task in ["A", "B", "C", "D", "E"]:
        await queue.put(task)
    
    await queue.join()  # 等待所有任务完成
    for w in workers:
        w.cancel()
```

### 3. **限流/背压**

```python
async def producer(queue: asyncio.Queue, max_size: int = 5):
    for i in range(100):
        await queue.put(i)  # 队列满时会阻塞
        print(f"生产: {i}")

async def consumer(queue: asyncio.Queue):
    while True:
        item = await queue.get()
        await asyncio.sleep(0.5)  # 模拟慢消费者
        print(f"消费: {item}")
        queue.task_done()

async def main():
    queue = asyncio.Queue(maxsize=5)  # 限制队列大小
    await asyncio.gather(producer(queue), consumer(queue))
```

### 4. **多协程结果收集**

```python
async def fetch_data(url: str, result_queue: asyncio.Queue):
    await asyncio.sleep(1)  # 模拟网络请求
    await result_queue.put({"url": url, "data": "some_data"})

async def main():
    urls = ["a.com", "b.com", "c.com"]
    queue = asyncio.Queue()
    
    tasks = [asyncio.create_task(fetch_data(url, queue)) for url in urls]
    await asyncio.gather(*tasks)
    
    results = []
    while not queue.empty():
        results.append(await queue.get())
    print(results)
```

### 在你代码中的使用

在你查看的 [manager.py](file:///Users/xiniuyiliao/Desktop/work_code/CoPaw/src/copaw/app/channels/manager.py#L121) 文件中，`self._queues` 字典存储了多个命名的 `asyncio.Queue`，这意味着它可能用于：

- **按通道隔离消息**：不同的通道/房间有不同的队列
- **消息广播**：向特定队列发送消息，只有关注该通道的消费者才会处理