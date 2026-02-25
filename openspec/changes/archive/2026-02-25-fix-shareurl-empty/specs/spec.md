## 新增需求

### 需求:保存关注时保留有效shareUrl
当保存关注用户时，如果已存在相同ID的记录且其shareUrl为非空值，而新数据的shareUrl为空，则必须保留原有的shareUrl不被覆盖。

#### 场景:原有shareUrl有效且新值为空
- **当** 已存在ID为"douyin_123"且shareUrl="https://live.douyin.com/abc"的关注用户，用户再次进入该直播间（此时shareUrl为空）并关注
- **那么** 系统中该用户的shareUrl必须保持为"https://live.douyin.com/abc"

#### 场景:原有shareUrl为空且新值有效
- **当** 已存在ID为"douyin_123"且shareUrl=""的关注用户，用户从带shareUrl的链接进入并关注
- **那么** 系统中该用户的shareUrl必须更新为新的有效值

#### 场景:新数据本身有shareUrl
- **当** 用户从带有效shareUrl的链接进入直播间并关注
- **那么** 系统中该用户的shareUrl必须更新为新的有效值
