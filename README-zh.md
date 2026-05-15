# Kubernetes NFS Subdir External Provisioner

**NFS subdir external provisioner** 是一个 Kubernetes 外部动态存储卷自动供应器。它利用现有的 NFS 服务器，通过 Persistent Volume Claims（PVC）动态创建和管理 Persistent Volumes（PV）。每个 PV 以 `${namespace}-${pvcName}-${pvName}` 格式作为 NFS 共享上的子目录。

> **说明**: 本项目从 [kubernetes-incubator/external-storage](https://github.com/kubernetes-incubator/external-storage/tree/master/nfs-client) 迁移而来。容器镜像已变更为 `registry.k8s.io/sig-storage/nfs-subdir-external-provisioner`。为保持向后兼容，部署 YAML 中仍沿用 `nfs-client-provisioner` 的命名。

---

## 架构与技术原理

### 整体架构

```
┌──────────────────────────────────────────────────────────────┐
│                     Kubernetes Cluster                        │
│                                                               │
│  ┌──────────────┐    ┌───────────────────────────────────┐   │
│  │     PVC      │    │  NFS Subdir External Provisioner   │   │
│  │ (用户声明存储) │───▶│  ┌─────────────────────────────┐  │   │
│  └──────────────┘    │  │     ProvisionController       │  │   │
│                       │  │  (sig-storage-lib-            │  │   │
│  ┌──────────────┐    │  │   external-provisioner)       │  │   │
│  │     PV       │◀───│  │          │                     │  │   │
│  │ (动态创建卷)  │    │  │          ▼                     │  │   │
│  └──────────────┘    │  │  ┌─────────────────────────┐  │  │   │
│                       │  │  │     nfsProvisioner      │  │  │   │
│                       │  │  │  (Provision / Delete)   │  │  │   │
│                       │  │  └───────────┬─────────────┘  │  │   │
│                       │  └──────────────┼────────────────┘  │   │
│                       │                 │                    │   │
│                       │  ┌──────────────▼─────────────────┐ │   │
│                       │  │   /persistentvolumes            │ │   │
│                       │  │   (容器内 NFS 挂载点)            │ │   │
│                       │  └──────────────┬─────────────────┘ │   │
│                       └─────────────────┼───────────────────┘   │
│                                         │                        │
└─────────────────────────────────────────┼────────────────────────┘
                                          │
                                          ▼
                              ┌───────────────────────┐
                              │     NFS Server         │
                              │  /exported/path/        │
                              │    ├── ns-pvc-pv-xxxx/  │
                              │    ├── archived-xxx/     │
                              │    └── ...               │
                              └───────────────────────┘
```

### 核心设计模式：外部供应器

本组件遵循 Kubernetes SIG Storage 定义的 [外部供应器](https://github.com/kubernetes-sigs/sig-storage-lib-external-provisioner) 规范：

1. **接口实现**: `nfsProvisioner` 结构体实现了 `controller.Provisioner` 接口的两个核心方法：
   - `Provision(ctx, opts) (*PersistentVolume, ProvisioningState, error)` — 响应 PVC 创建事件，分配存储
   - `Delete(ctx, volume) error` — 响应 PV 删除事件，回收存储

2. **事件驱动**: `ProvisionController` 通过 Kubernetes API Watch 机制监听 PVC/PV 资源变更，自动回调对应的供应和删除方法。

3. **Leader Election**: 多副本部署时通过 Kubernetes Endpoints 和 Leases 资源进行选主，确保仅有一个实例处理供应请求。

### Provision（存储供应）流程

```
用户创建PVC → StorageClass匹配 → ProvisionController 调用 Provision()
    │
    ├── 1. 校验 PVC（不支持 Selector，直接拒绝）
    ├── 2. 解析 pathPattern 模板参数
    │      语法: ${.PVC.namespace}, ${.PVC.name},
    │            ${.PVC.labels.<key>}, ${.PVC.annotations.<key>}
    │      默认: {namespace}-{pvcName}-{pvName}
    ├── 3. 确定目录权限和所有权
    │      优先级: PVC Annotations > 环境变量 > root:root 0777
    │      Annotations:
    │        k8s-sigs.io/nfs-directory-mode  (八进制, 如 0755)
    │        k8s-sigs.io/nfs-directory-uid   (数字UID)
    │        k8s-sigs.io/nfs-directory-gid   (数字GID)
    ├── 4. 在 /persistentvolumes/ 下执行:
    │      os.MkdirAll() → os.Chmod() → os.Chown()
    └── 5. 构造 NFS 类型 PV 对象返回
           Server: <NFS_SERVER>
           Path:   <NFS_PATH>/<解析后的目录路径>
```

### Delete（存储回收）流程

```
用户删除PVC → ProvisionController 调用 Delete()
    │
    ├── 1. 检查 NFS 目录是否存在，不存在则跳过
    ├── 2. 读取 StorageClass 参数决定回收行为:
    │
    │   onDelete 参数 (最高优先级):
    │     ├── "delete" → os.RemoveAll() 彻底删除
    │     └── "retain" → 保留，不做处理
    │
    │   archiveOnDelete 参数 (onDelete 不存在时生效):
    │     ├── "false" → os.RemoveAll() 彻底删除
    │     └── "true" 或未设置 → os.Rename() 归档
    │         归档路径: /persistentvolumes/archived-{pvName}
    │
    └── 归档机制防止误删，可在 NFS 服务器上手动恢复
```

### 目录结构

```
.
├── cmd/nfs-subdir-external-provisioner/
│   └── provisioner.go          # 唯一入口，实现 Provisioner 接口
├── version/
│   └── version.go              # 版本信息，ldflags 注入编译时变量
├── build/
│   └── Dockerfile              # 多阶段构建（golang builder → distroless runtime）
├── deploy/                     # Kubernetes 原生部署清单
│   ├── class.yaml              # StorageClass 定义
│   ├── deployment.yaml         # Deployment（含 NFS 卷挂载）
│   ├── rbac.yaml               # ServiceAccount + ClusterRole + Role + Binding
│   ├── test-claim.yaml         # 测试 PVC
│   └── test-pod.yaml           # 测试 Pod
├── charts/                     # Helm Chart
├── Makefile                    # 构建、容器化、多架构支持
└── CHANGELOG/                  # 版本变更日志
```

### 核心依赖

| 依赖 | 作用 |
|---|---|
| `k8s.io/client-go` | Kubernetes API 客户端 |
| `k8s.io/api` | 核心 API 类型定义 |
| `k8s.io/component-helpers` | `GetPersistentVolumeClass` 辅助函数 |
| `sigs.k8s.io/sig-storage-lib-external-provisioner/v6` | 外部供应器框架，提供 `ProvisionController` 和 `Provisioner` 接口 |
| `github.com/golang/glog` | 日志记录 |

### 容器镜像构建架构

```
Stage 1 — builder (golang:1.26.2-alpine3.23)
  ├── CGO_ENABLED=0 静态编译
  ├── GOOS/GOARCH 交叉编译目标平台
  └── -ldflags 注入 Version、GitCommit、BuildDate

Stage 2 — runtime (distroless/static-debian13)
  ├── 最小化攻击面(无 shell、无包管理器)
  ├── COPY --from=builder 仅二进制
  └── ENTRYPOINT ["/nfs-subdir-external-provisioner"]
```

---

## 部署方式

### 前提

集群必须能访问已存在的 NFS 服务器。

### 方式一：Helm

```bash
helm repo add nfs-subdir-external-provisioner \
  https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/

helm install nfs-subdir-external-provisioner \
  nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
  --set nfs.server=<NFS_SERVER_IP> \
  --set nfs.path=<NFS_EXPORT_PATH>
```

### 方式二：Kustomize

```yaml
# kustomization.yaml
namespace: nfs-provisioner
bases:
  - github.com/kubernetes-sigs/nfs-subdir-external-provisioner//deploy

resources:
  - namespace.yaml

patchesStrategicMerge:
  - patch_nfs_details.yaml
```

在 `patch_nfs_details.yaml` 中填入 NFS 服务器信息后执行 `kubectl apply -k .`。

### 方式三：手动部署

**配置 RBAC**（Kubernetes）:
```bash
NS=$(kubectl config get-contexts | grep -e "^\*" | awk '{print $5}')
NAMESPACE=${NS:-default}
sed -i'' "s/namespace:.*/namespace: $NAMESPACE/g" ./deploy/rbac.yaml ./deploy/deployment.yaml
kubectl create -f deploy/rbac.yaml
```

**配置 RBAC**（OpenShift）:
```bash
NAMESPACE=$(oc project -q)
sed -i'' "s/namespace:.*/namespace: $NAMESPACE/g" ./deploy/rbac.yaml ./deploy/deployment.yaml
oc create -f deploy/rbac.yaml
oc adm policy add-scc-to-user hostmount-anyuid \
  system:serviceaccount:$NAMESPACE:nfs-client-provisioner
```

编辑 `deploy/deployment.yaml` 中的 `NFS_SERVER` 和 `NFS_PATH`，然后部署 StorageClass 和 Deployment：
```bash
kubectl create -f deploy/class.yaml -f deploy/deployment.yaml
```

### 验证

```bash
kubectl create -f deploy/test-claim.yaml -f deploy/test-pod.yaml
```

检查 NFS 服务器上 PVC 目录中是否出现 `SUCCESS` 文件。清理：
```bash
kubectl delete -f deploy/test-pod.yaml -f deploy/test-claim.yaml
```

---

## 配置参考

### 环境变量

| 变量 | 必填 | 说明 | 默认值 |
|---|---|---|---|
| `NFS_SERVER` | 是 | NFS 服务器 IP 或主机名 | — |
| `NFS_PATH` | 是 | NFS 导出路径 | — |
| `PROVISIONER_NAME` | 是 | 须与 StorageClass 的 `provisioner` 字段一致 | `k8s-sigs.io/nfs-subdir-external-provisioner` |
| `NFS_DEFAULT_MODE` | 否 | 新建目录的文件模式（八进制） | `0777` |
| `NFS_DEFAULT_UID` | 否 | 新建目录所有者 UID | `0` |
| `NFS_DEFAULT_GID` | 否 | 新建目录组 GID | `0` |
| `ENABLE_LEADER_ELECTION` | 否 | 是否启用选主 | `true` |
| `KUBECONFIG` | 否 | 集群外运行时 kubeconfig 路径 | — |

### StorageClass 参数

| 参数 | 说明 | 默认值 |
|---|---|---|
| `pathPattern` | 自定义目录路径模板，支持 PVC 元数据变量 | `${namespace}-${pvcName}-${pvName}` |
| `onDelete` | `delete` 删除目录，`retain` 保留目录 | 由 `archiveOnDelete` 决定 |
| `archiveOnDelete` | `false` 删除目录；`true` 归档为 `archived-{pvName}` | `true` |

### PVC 注解

| 注解 | 说明 |
|---|---|
| `k8s-sigs.io/nfs-directory-mode` | 该 PVC 目录的文件模式（如 `0755`） |
| `k8s-sigs.io/nfs-directory-uid` | 该 PVC 目录的所有者 UID |
| `k8s-sigs.io/nfs-directory-gid` | 该 PVC 目录的组 GID |

### 自定义 StorageClass 示例

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-client
provisioner: k8s-sigs.io/nfs-subdir-external-provisioner
parameters:
  pathPattern: "${.PVC.namespace}/${.PVC.annotations.nfs.io/storage-path}"
  onDelete: delete
```

### 自定义 PVC 示例

```yaml
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: test-claim
  annotations:
    nfs.io/storage-path: "test-path"
    k8s-sigs.io/nfs-directory-mode: "0755"
    k8s-sigs.io/nfs-directory-uid: "1000"
    k8s-sigs.io/nfs-directory-gid: "1000"
spec:
  storageClassName: nfs-client
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Mi
```

---

## 构建自定义镜像

```bash
make build       # 编译二进制 → bin/nfs-subdir-external-provisioner
make docker-build  # 构建当前架构镜像
make docker-buildx # 构建多架构镜像 (linux/amd64, linux/arm64) 并推送
```

### GitHub Actions 自动构建

推送 `gh-v*.*.*` 格式 tag 可触发 CI 流水线（`.github/workflows/release.yml`），自动构建三架构镜像（amd64、arm64、arm/v7）并推送至 quay.io。需配置 Secrets：`REGISTRY_USERNAME`、`REGISTRY_TOKEN`、`DOCKER_IMAGE`。

---

## 限制与注意事项

- **存储容量无保障**: 声明的容量可能超过 NFS 共享实际大小，共享剩余空间不足时写入会失败。
- **存储限额不强制执行**: 应用可超出 PVC 声明大小写入数据，不受限制。
- **不支持存储扩容**: PVC 扩容请求会进入错误状态：`Ignoring the PVC: didn't find a plugin capable of expanding the volume`。
