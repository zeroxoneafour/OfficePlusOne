class_name Http extends RefCounted
## Minimal awaitable HTTP helper built on HTTPRequest nodes.
## Returns {"ok": bool, "code": int, "body": PackedByteArray, "error": String}


static func request(host: Node, url: String, headers: PackedStringArray, method := HTTPClient.METHOD_GET,
		body := PackedByteArray(), timeout := 120.0) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = timeout
	req.use_threads = true
	req.body_size_limit = 16 * 1024 * 1024
	host.add_child(req)
	var err := req.request_raw(url, headers, method, body)
	if err != OK:
		req.queue_free()
		return {"ok": false, "code": 0, "body": PackedByteArray(), "error": "request failed: %s" % error_string(err)}
	var res: Array = await req.request_completed
	req.queue_free()
	var result: int = res[0]
	var code: int = res[1]
	if result != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "code": code, "body": PackedByteArray(), "error": "network error %d" % result}
	return {"ok": code >= 200 and code < 300, "code": code, "body": res[3], "error": "" if code < 300 else "HTTP %d" % code}


static func post_json(host: Node, url: String, headers: PackedStringArray, payload: Dictionary, timeout := 120.0) -> Dictionary:
	var h := headers.duplicate()
	h.append("content-type: application/json")
	return await request(host, url, h, HTTPClient.METHOD_POST, JSON.stringify(payload).to_utf8_buffer(), timeout)
