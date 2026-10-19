#!/bin/bash
set -euo pipefail

daemon=$1
last_node=$((${NODES:?set NODES to the number of compute nodes} - 1))

cat >/etc/slurm/slurm.conf <<EOF
ClusterName=cs5424
SlurmctldHost=xlogin
ProctrackType=proctrack/linuxproc
TaskPlugin=task/none
SlurmdParameters=config_overrides
MailProg=/bin/true
NodeName=xcnc[0-$last_node] CPUs=4 Features=xcnc
PartitionName=normal Nodes=xcnc[0-$last_node] Default=YES MaxTime=03:00:00 State=UP
EOF

mkdir -p /run/munge "/var/spool/$daemon"
chown munge: /run/munge
runuser -u munge -- munged
exec "$daemon" -D
