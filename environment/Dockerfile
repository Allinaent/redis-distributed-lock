FROM python:3.11-slim

WORKDIR /app

# Install Redis and other dependencies
RUN apt-get update && apt-get install -y redis-server gcc

# Install Python dependencies
RUN pip install redis pytest

# Configure Redis
RUN mkdir -p /var/run/redis /var/log/redis /var/lib/redis && \
    echo "daemonize yes" >> /etc/redis/redis.conf && \
    echo "bind 127.0.0.1" >> /etc/redis/redis.conf && \
    echo "dir /var/lib/redis" >> /etc/redis/redis.conf

CMD ["bash"]
