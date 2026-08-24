// 表示層 Washi は解析層 WashiCore を @_exported で再輸出する。
// これにより従来どおり `import Washi` だけで解析層の公開 API
// (EPUBPublication・EPUBLocator・メタデータ等)も見える。
// ヘッドレス利用(CLI・サーバ)は `import WashiCore` だけで足りる。
@_exported import WashiCore
