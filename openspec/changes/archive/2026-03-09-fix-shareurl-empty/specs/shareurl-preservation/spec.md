## 新增需求

### 需求:同步关注数据时保留有效 shareUrl
当从云端或其他设备同步关注数据时，如果本地已存在相同 ID 的记录且其 shareUrl 为非空值，而同步数据的 shareUrl 为空，则必须保留本地的 shareUrl 不被覆盖。

#### 场景:本地 shareUrl 有效且同步数据为空
- **当** 本地已存在 ID 为"douyin_123"且 shareUrl="https://live.douyin.com/abc"的关注用户，从云端同步的数据中该用户 shareUrl 为空
- **那么** 系统中该用户的 shareUrl 必须保持为"https://live.douyin.com/abc"，不被同步数据覆盖

#### 场景:本地 shareUrl 为空且同步数据有效
- **当** 本地已存在 ID 为"douyin_123"且 shareUrl=""的关注用户，从云端同步的数据中该用户 shareUrl 为有效值
- **那么** 系统中该用户的 shareUrl 必须更新为同步数据中的有效值

## 修改需求

### 需求:保存关注时保留有效 shareUrl
当保存关注用户时，如果已存在相同 ID 的记录且其 shareUrl 为非空值，而新数据的 shareUrl 为空，则必须保留原有的 shareUrl 不被覆盖。此外，如果新数据包含有效的 shareUrl，则必须更新数据库中的值。

#### 场景:原有 shareUrl 有效且新值为空
- **当** 已存在 ID 为"douyin_123"且 shareUrl="https://live.douyin.com/abc"的关注用户，用户再次进入该直播间（此时 shareUrl 为空）并关注
- **那么** 系统中该用户的 shareUrl 必须保持为"https://live.douyin.com/abc"

#### 场景:原有 shareUrl 为空且新值有效
- **当** 已存在 ID 为"douyin_123"且 shareUrl=""的关注用户，用户从带 shareUrl 的链接进入并关注
- **那么** 系统中该用户的 shareUrl 必须更新为新的有效值

#### 场景:新数据本身有 shareUrl
- **当** 用户从带有效 shareUrl 的链接进入直播间并关注
- **那么** 系统中该用户的 shareUrl 必须更新为新的有效值

#### 场景:直播间加载后获取到 shareUrl
- **当** 用户进入直播间时 shareUrl 为空，但直播间信息加载完成后获取到了有效的 shareUrl
- **那么** 系统必须将该 shareUrl 保存到数据库中的关注记录
