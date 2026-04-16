# 分布式锁实现

你需要实现一个基于 Redis 的分布式锁，支持可重入、自动续期和防死锁。

## 背景

在分布式系统中，多个服务实例需要协调对共享资源的访问。你需要实现一个可靠的分布式锁机制。

## 任务

实现一个 Python 类 `DistributedLock`，保存到 `/app/distributed_lock.py`：

### 功能要求

1. **基本加锁/解锁**
   - `acquire(timeout=30)` - 获取锁，支持阻塞等待
   - `release()` - 释放锁
   - 使用 Redis 作为后端存储

2. **可重入性**
   - 同一个线程/协程可以多次获取同一把锁
   - 需要记录重入次数
   - 释放时只有重入次数归零才真正释放

3. **自动续期（Watchdog）**
   - 锁有过期时间（默认 30 秒）
   - 如果持有锁的线程还在运行，自动续期
   - 防止业务逻辑执行时间超过锁过期时间

4. **防死锁**
   - 锁必须有过期时间
   - 支持锁的强制释放（当持有者崩溃时）

5. **Redlock 算法支持（可选加分）**
   - 在多个 Redis 节点上实现 Redlock 算法
   - 提高锁的可靠性

## 接口定义

```python
class DistributedLock:
    def __init__(self, redis_client, lock_name, expire_time=30):
        """
        Initialize distributed lock
        :param redis_client: Redis client instance
        :param lock_name: Unique name for this lock
        :param expire_time: Lock expiration time in seconds
        """
        pass
    
    def acquire(self, blocking=True, timeout=None):
        """
        Acquire the lock
        :param blocking: If True, block until lock is acquired
        :param timeout: Maximum time to wait for lock
        :return: True if lock acquired, False otherwise
        """
        pass
    
    def release(self):
        """Release the lock"""
        pass
    
    def __enter__(self):
        """Context manager entry"""
        pass
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit"""
        pass
```

## 测试要求

创建 `/app/test_lock.py` 进行测试：

1. **并发测试**：10 个线程同时竞争锁，确保只有一个能获得
2. **可重入测试**：同一线程多次获取锁，验证重入计数
3. **续期测试**：持有锁超过过期时间，验证自动续期
4. **死锁恢复测试**：模拟持有者崩溃，验证其他线程能获取锁

## 输出

- `/app/distributed_lock.py` - 锁的实现
- `/app/test_lock.py` - 测试代码
- `/app/test_report.txt` - 测试结果摘要

## 验证

运行 `python /app/test_lock.py` 应该输出所有测试通过的信息。
