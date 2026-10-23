# BaseURL和APIkey

简单来说，API Key 就是一张“AI 饭卡”

HerMemory的运行依赖AI。

AI运行在厂商的服务器上，需要用一个”接口“去调用。

BaseURL 即”食堂地址“，决定你从哪里调用。

APIkey则是你账号的”饭卡密钥“，用于鉴权和用量统计。

> 💡 **注意**：最好不要将明文APIkey发给他人

## 怎么获取BaseURL和APIkey？

- **官网注册**：找到官方网站注册登录，例如DeepSeek开放平台
- **复制地址**：在平台的文档找到OpenAI协议的BaseURL，通常以v1结尾
- **创建密钥**：进入控制台，找到 **「API Key」** ，点击 **「创建API Key」**
- **粘贴**：将BaseURL和APIkey粘贴到文本框

## Q&A

**Q：APIkey需要付费吗？**

A：AI运行通常都需要付费。

**Q：为什么豆包和DeepSeek手机APP和网页版不付费？**

A：这类APP由厂商自费补贴，用于引流。免费的AI通常智力不高且用量受限。

**Q：有没有什么免费的APIkey获取途径？**

A：很多，可以自行搜索关键词【免费APIkey】建议选择正规厂商。

**Q：为什么不把APIkey内置到HerMemory？**

A：HerMemory纯粹开源、注重数据主权，不做商业化推广。自己填写API，你才能获得完全的自由与隐私。
