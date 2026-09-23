package cn.imsummer.simple_reader

import org.json.JSONObject
import org.json.JSONTokener

/**
 * 官方 Web 端登录凭证的读取与解析，供两处共用：
 *
 * 1. [BrowserActivity] —— 登录页（auth）轮询/主动读取、网页版（web）静默同步；
 * 2. [MainActivity]    —— 离屏静默检测（peek，不打开可见页面）。
 *
 * 读取策略分两层：
 *
 * 1. 主键 `flutter.UserInfo`（shared_preferences 的 Web 实现统一加 `flutter.`
 *    前缀，来自官方 main.dart.js 静态分析，见探查报告）；
 * 2. 主键缺失或字段为空时，兜底扫描 localStorage：键名含 UserInfo/token、
 *    值为 JSON 且内含 `eyJ` 开头 token 字段的，视为候选——即便官方日后
 *    改了键名也能取到。
 *
 * 两层都读不到时把 localStorage 的键名快照（截断到 25 个）一并带回，
 * 落进运行日志：下次「读不到凭证」可以直接对照官方实际写了哪些键。
 */
object WebAuthProbe {

    /** 官方 Web 端首页。 */
    const val WEB_HOME = "https://simple.imsummer.cn/web"

    /**
     * 在官方 Web 端 origin 的任意页面里执行，读取登录信息。
     * 返回值经 evaluateJavascript 回调时会被再包一层 JSON 引号，
     * 由 [parse] 统一反转义。
     */
    val JS: String =
        "(function(){try{" +
            "var raw=localStorage.getItem('flutter.UserInfo');" +
            "var peek='';" +
            "if(raw){peek=raw.slice(0,240);" +
            // 官方存入的是「JSON 字符串的字面量」（对象先被 encode 成字符串
            // 再落 localStorage），必须二次解码：首次 parse 得到的若仍是
            // 字符串，再 parse 一次才是用户信息对象。
            "var o=null;try{o=JSON.parse(raw);}catch(e1){}" +
            "if(typeof o==='string'){try{o=JSON.parse(o);}catch(e2){o=null;}}" +
            "if(o&&typeof o==='object'){var t=o.token||'',a=o.auth_token||'';" +
            "if(t||a)return JSON.stringify({found:true,token:t,authToken:a});}}" +
            "var keys=[],i,k;" +
            "for(i=0;i<localStorage.length;i++){k=localStorage.key(i);if(k)keys.push(k);}" +
            "for(i=0;i<keys.length;i++){k=keys[i];" +
            "if(k==='flutter.UserInfo')continue;" +
            "if(k.indexOf('UserInfo')<0&&k.toLowerCase().indexOf('token')<0)continue;" +
            "var v=localStorage.getItem(k)||'';" +
            "if(v.length<40||v.length>8192)continue;" +
            "try{var oo=JSON.parse(v);" +
            "if(typeof oo==='string'){try{oo=JSON.parse(oo);}catch(e3){oo=null;}}" +
            "if(oo&&typeof oo==='object'){var t2=oo.token||oo.auth_token||'';" +
            "if(typeof t2==='string'&&t2.indexOf('eyJ')===0)" +
            "return JSON.stringify({found:true,token:t2,authToken:oo.auth_token||''});}}" +
            "catch(e2){}}" +
            "return JSON.stringify({found:false,keys:keys.slice(0,25).join(',')," +
            "diag:'UserInfo='+(peek||'<null>')});" +
        "}catch(e){return JSON.stringify({found:false,diag:'ERR:'+e.message})}})()"

    /** 一次读取的结果。 */
    class Result private constructor(
        /** 是否拿到候选凭证（token 与 authToken 至少一个非空）。 */
        @JvmField val found: Boolean,
        @JvmField val token: String,
        @JvmField val authToken: String,
        /** 未找到时的 localStorage 键名快照，供日志诊断键名漂移。 */
        @JvmField val keys: String,
        /** 未找到时的诊断信息（主键原始值摘要 / 解析异常），供日志定位。 */
        @JvmField val diag: String,
    ) {
        companion object {
            fun hit(token: String, authToken: String) =
                Result(true, token, authToken, "", "")

            fun miss(keys: String = "", diag: String = "") =
                Result(false, "", "", keys, diag)
        }
    }

    /** 解析 evaluateJavascript 的返回值：先反转义一层，再解析 JSON。 */
    fun parse(raw: String?): Result {
        return try {
            val value = JSONTokener(raw ?: "null").nextValue()
            val s = value as? String
                ?: return Result.miss(diag = "non-string:${raw?.take(60)}")
            val obj = JSONObject(s)
            if (!obj.optBoolean("found")) {
                return Result.miss(obj.optString("keys", ""), obj.optString("diag", ""))
            }
            val token = obj.optString("token", "")
            val authToken = obj.optString("authToken", "")
            if (token.isEmpty() && authToken.isEmpty()) {
                Result.miss(diag = "empty-fields")
            } else {
                Result.hit(token, authToken)
            }
        } catch (e: Exception) {
            Result.miss(diag = "parse-err:${e.message?.take(80)}")
        }
    }
}
