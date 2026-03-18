
project_dir=$(dirname $(dirname $0))

log_dir=${project_dir}/logs
mkdir -p ${log_dir}

nohup copaw app > ${log_dir}/run.log 2>&1 &


echo "CoPaw is running in background, check ${log_dir}/run.log for more details"


# 将 当前启动脚本 进程的 pid 写入日志
echo "CoPaw pid: $!" >> ${log_dir}/run.log

