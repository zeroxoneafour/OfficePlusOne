class_name Exporter
extends RefCounted
## Builds "export" files that AI agents hand off to the user (server side)
## and saves them to local disk (client side). A "file" is always a
## Dictionary: {"filename": String, "bytes": PackedByteArray}.
##
## Slide decks come from LLM tool-call JSON, so every entry point here is
## defensive about missing keys and wrong types.

const MAX_FILENAME_LEN := 80
const EXPORT_SUBDIR := "exports"
const DOCUMENTS_SUBDIR := "OfficePlusOne"

const _ILLEGAL_CHARS: Array[String] = [
	"/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\n", "\r", "\t",
]


#region filenames

## Strips path separators/illegal characters, trims Windows-unsafe leading
## and trailing dots/spaces, limits length to 80, and ensures an extension.
static func sanitize_filename(name: String, default_ext := ".txt") -> String:
	var n := str(name).strip_edges()
	for ch in _ILLEGAL_CHARS:
		n = n.replace(ch, "_")
	while n.begins_with(".") or n.begins_with(" "):
		n = n.substr(1)
	while n.ends_with(".") or n.ends_with(" "):
		n = n.substr(0, n.length() - 1)
	if n.strip_edges() == "":
		n = "export"

	var ext := default_ext if default_ext.begins_with(".") else "." + default_ext
	if not _has_real_extension(n):
		n += ext

	if n.length() > MAX_FILENAME_LEN:
		var cur_ext := n.get_extension()
		var ext_suffix := ("." + cur_ext) if cur_ext != "" else ""
		var max_base: int = maxi(MAX_FILENAME_LEN - ext_suffix.length(), 1)
		n = n.get_basename().substr(0, max_base) + ext_suffix
	return n


## Godot's String.get_extension() treats anything after the last "." as an
## extension, even leftover punctuation-turned-underscores from sanitizing
## (e.g. "_.._etc_passwd"). Require a short alphanumeric suffix instead, so
## we don't skip appending a real extension in those cases.
static func _has_real_extension(n: String) -> bool:
	var dot := n.rfind(".")
	if dot <= 0 or dot == n.length() - 1:
		return false
	var ext := n.substr(dot + 1)
	if ext.length() > 8:
		return false
	for i in ext.length():
		var c := ext.unicode_at(i)
		var is_alnum := (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
		if not is_alnum:
			return false
	return true


## Directory (in user://) where exports are staged before copying out.
static func export_dir() -> String:
	return "user://" + EXPORT_SUBDIR

#endregion


#region text files

## Plain UTF-8 text file (md, txt, csv, json, html, svg, ...).
static func make_text(filename: String, content: String) -> Dictionary:
	return {
		"filename": sanitize_filename(filename),
		"bytes": str(content).to_utf8_buffer(),
	}

#endregion


#region slide decks

## Builds an HTML deck, a Markdown outline, and (if it can be made valid) a
## PPTX for the same slides. Returns an Array of file Dictionaries.
static func make_slides(title: String, slides: Array) -> Array:
	var deck_title := str(title).strip_edges()
	if deck_title == "":
		deck_title = "Presentation"
	var norm := _normalize_slides(slides)
	# Route the title through sanitize_filename once to get a clean, length
	# limited base name shared by all three output files.
	var base := sanitize_filename(deck_title, ".html").get_basename()

	var out: Array = []
	out.append(make_text(base + ".html", _build_html(deck_title, norm)))
	out.append(make_text(base + ".md", _build_markdown(deck_title, norm)))

	var pptx_bytes := _build_pptx(deck_title, norm)
	if pptx_bytes.size() > 0:
		out.append({
			"filename": sanitize_filename(base + ".pptx"),
			"bytes": pptx_bytes,
		})
	return out


## Coerces an arbitrary (LLM-supplied) Array into a clean
## Array[Dictionary] with title: String, bullets: Array[String],
## notes: String, svg: String (empty when absent or implausible).
static func _normalize_slides(slides: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw in slides:
		var s: Dictionary = raw if raw is Dictionary else {}

		var slide_title := str(s.get("title", "")).strip_edges()

		var bullets: Array[String] = []
		var raw_bullets = s.get("bullets", [])
		if raw_bullets is Array:
			for b in raw_bullets:
				var bt := str(b).strip_edges()
				if bt != "":
					bullets.append(bt)

		var notes := str(s.get("notes", "")).strip_edges()

		var svg := str(s.get("svg", "")).strip_edges()
		if not svg.to_lower().begins_with("<svg"):
			svg = ""

		out.append({
			"title": slide_title,
			"bullets": bullets,
			"notes": notes,
			"svg": svg,
		})
	return out


static func _escape(value) -> String:
	return str(value).replace("&", "&amp;").replace("<", "&lt;") \
		.replace(">", "&gt;").replace("\"", "&quot;").replace("'", "&#39;")

#endregion


#region HTML deck

const _HTML_CSS := (
	":root{color-scheme:dark}\n" +
	"*{box-sizing:border-box}\n" +
	"html,body{height:100%;margin:0}\n" +
	"body{background:#14161a;color:#f0f0f0;font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;overflow:hidden}\n" +
	".deck{width:100%;height:100vh;position:relative}\n" +
	".slide{position:absolute;inset:0;display:none;flex-direction:column;justify-content:center;padding:6vh 8vw;overflow:auto}\n" +
	".slide.active{display:flex}\n" +
	".slide h1{font-size:clamp(1.6em,4vw,3em);margin:0 0 0.6em 0;border-bottom:2px solid #3a6ea5;padding-bottom:0.2em}\n" +
	".slide ul{font-size:clamp(1em,2.2vw,1.5em);line-height:1.6em;margin:0;padding-left:1.2em}\n" +
	".slide .svg-wrap{margin-top:1em;max-width:100%;max-height:45vh;display:flex}\n" +
	".slide .svg-wrap svg{max-width:100%;max-height:45vh}\n" +
	".counter{position:fixed;bottom:14px;right:20px;opacity:0.55;font-size:0.9em}\n" +
	".hint{position:fixed;bottom:14px;left:20px;opacity:0.35;font-size:0.8em}\n" +
	".notes-body{display:none;margin-top:1.2em;padding:0.8em 1em;background:#1f232b;border-left:3px solid #6a8caf;font-size:0.85em;opacity:0.9;max-width:70ch}\n" +
	"body.show-notes .notes-body{display:block}"
)

const _HTML_JS := (
	"var slides=document.querySelectorAll('.slide');" +
	"var i=0;" +
	"var counter=document.getElementById('counter');" +
	"function render(){" +
	"for(var k=0;k<slides.length;k++){slides[k].classList.toggle('active',k===i);}" +
	"counter.textContent=(i+1)+' / '+slides.length;" +
	"}" +
	"function next(){if(i<slides.length-1){i++;render();}}" +
	"function prev(){if(i>0){i--;render();}}" +
	"document.addEventListener('keydown',function(e){" +
	"if(e.key==='ArrowRight'||e.key===' '||e.key==='PageDown'){next();e.preventDefault();}" +
	"else if(e.key==='ArrowLeft'||e.key==='PageUp'){prev();e.preventDefault();}" +
	"else if(e.key==='n'||e.key==='N'){document.body.classList.toggle('show-notes');}" +
	"});" +
	"document.getElementById('deck').addEventListener('click',function(){next();});" +
	"render();"
)


static func _build_html(title: String, slides: Array[Dictionary]) -> String:
	var parts: Array[String] = []
	parts.append(
		"<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n" +
		"<title>" + _escape(title) + "</title>\n<style>\n" + _HTML_CSS + "\n</style>\n" +
		"</head>\n<body>\n<div class=\"deck\" id=\"deck\">\n"
	)
	if slides.is_empty():
		slides = [{"title": title, "bullets": [], "notes": "", "svg": ""}]
	for i in range(slides.size()):
		parts.append(_html_slide(slides[i], i == 0))
	parts.append(
		"</div>\n<div class=\"counter\" id=\"counter\"></div>\n" +
		"<div class=\"hint\">&larr;/&rarr;/space: navigate &middot; n: notes</div>\n" +
		"<script>\n" + _HTML_JS + "\n</script>\n</body>\n</html>\n"
	)
	return "".join(parts)


static func _html_slide(slide: Dictionary, is_first: bool) -> String:
	var s := "<div class=\"" + ("slide active" if is_first else "slide") + "\">\n"
	s += "<h1>" + _escape(slide.get("title", "")) + "</h1>\n"

	var bullets: Array = slide.get("bullets", [])
	if bullets.size() > 0:
		s += "<ul>\n"
		for b in bullets:
			s += "<li>" + _escape(b) + "</li>\n"
		s += "</ul>\n"

	var svg := str(slide.get("svg", ""))
	if svg != "":
		s += "<div class=\"svg-wrap\">" + svg + "</div>\n"

	var notes := str(slide.get("notes", ""))
	if notes != "":
		s += "<div class=\"notes-body\"><strong>Notes:</strong> " + \
			_escape(notes).replace("\n", "<br>") + "</div>\n"

	s += "</div>\n"
	return s

#endregion


#region Markdown outline

static func _build_markdown(title: String, slides: Array[Dictionary]) -> String:
	var lines: Array[String] = ["# " + title, ""]
	for slide in slides:
		lines.append("## " + str(slide.get("title", "")))
		lines.append("")

		var bullets: Array = slide.get("bullets", [])
		for b in bullets:
			lines.append("- " + str(b))
		if bullets.size() > 0:
			lines.append("")

		var notes := str(slide.get("notes", ""))
		if notes != "":
			for note_line in notes.split("\n"):
				lines.append("> " + note_line)
			lines.append("")

		var svg := str(slide.get("svg", ""))
		if svg != "":
			lines.append("```svg")
			lines.append(svg)
			lines.append("```")
			lines.append("")
	return "\n".join(lines)

#endregion


#region PPTX deck

const _PPTX_RELS_ROOT := "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + \
	"<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" + \
	"<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"ppt/presentation.xml\"/>" + \
	"<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>" + \
	"<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties\" Target=\"docProps/app.xml\"/>" + \
	"</Relationships>"

const _PPTX_THEME := "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + \
	"<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"Office Plus One\">" + \
	"<a:themeElements>" + \
	"<a:clrScheme name=\"Office\">" + \
	"<a:dk1><a:sysClr val=\"windowText\" lastClr=\"000000\"/></a:dk1>" + \
	"<a:lt1><a:sysClr val=\"window\" lastClr=\"FFFFFF\"/></a:lt1>" + \
	"<a:dk2><a:srgbClr val=\"1F497D\"/></a:dk2>" + \
	"<a:lt2><a:srgbClr val=\"EEECE1\"/></a:lt2>" + \
	"<a:accent1><a:srgbClr val=\"4F81BD\"/></a:accent1>" + \
	"<a:accent2><a:srgbClr val=\"C0504D\"/></a:accent2>" + \
	"<a:accent3><a:srgbClr val=\"9BBB59\"/></a:accent3>" + \
	"<a:accent4><a:srgbClr val=\"8064A2\"/></a:accent4>" + \
	"<a:accent5><a:srgbClr val=\"4BACC6\"/></a:accent5>" + \
	"<a:accent6><a:srgbClr val=\"F79646\"/></a:accent6>" + \
	"<a:hlink><a:srgbClr val=\"0000FF\"/></a:hlink>" + \
	"<a:folHlink><a:srgbClr val=\"800080\"/></a:folHlink>" + \
	"</a:clrScheme>" + \
	"<a:fontScheme name=\"Office\">" + \
	"<a:majorFont><a:latin typeface=\"Calibri\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont>" + \
	"<a:minorFont><a:latin typeface=\"Calibri\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont>" + \
	"</a:fontScheme>" + \
	"<a:fmtScheme name=\"Office\">" + \
	"<a:fillStyleLst>" + \
	"<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>" + \
	"<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>" + \
	"<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>" + \
	"</a:fillStyleLst>" + \
	"<a:lnStyleLst>" + \
	"<a:ln w=\"6350\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln>" + \
	"<a:ln w=\"12700\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln>" + \
	"<a:ln w=\"19050\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln>" + \
	"</a:lnStyleLst>" + \
	"<a:effectStyleLst>" + \
	"<a:effectStyle><a:effectLst/></a:effectStyle>" + \
	"<a:effectStyle><a:effectLst/></a:effectStyle>" + \
	"<a:effectStyle><a:effectLst/></a:effectStyle>" + \
	"</a:effectStyleLst>" + \
	"<a:bgFillStyleLst>" + \
	"<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>" + \
	"<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>" + \
	"<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>" + \
	"</a:bgFillStyleLst>" + \
	"</a:fmtScheme>" + \
	"</a:themeElements>" + \
	"<a:objectDefaults/>" + \
	"<a:extraClrSchemeLst/>" + \
	"</a:theme>"

const _PPTX_SLIDE_MASTER := "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + \
	"<p:sldMaster xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\">" + \
	"<p:cSld>" + \
	"<p:bg><p:bgRef idx=\"1001\"><a:schemeClr val=\"bg1\"/></p:bgRef></p:bg>" + \
	"<p:spTree>" + \
	"<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>" + \
	"<p:grpSpPr/>" + \
	"</p:spTree>" + \
	"</p:cSld>" + \
	"<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>" + \
	"<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst>" + \
	"</p:sldMaster>"

const _PPTX_SLIDE_MASTER_RELS := "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + \
	"<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" + \
	"<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>" + \
	"<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme\" Target=\"../theme/theme1.xml\"/>" + \
	"</Relationships>"

const _PPTX_SLIDE_LAYOUT := "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + \
	"<p:sldLayout xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\" type=\"blank\" preserve=\"1\">" + \
	"<p:cSld name=\"Blank\">" + \
	"<p:spTree>" + \
	"<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>" + \
	"<p:grpSpPr/>" + \
	"</p:spTree>" + \
	"</p:cSld>" + \
	"<p:clrMapOvr><a:overrideClrMapping/></p:clrMapOvr>" + \
	"</p:sldLayout>"

const _PPTX_SLIDE_LAYOUT_RELS := "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + \
	"<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" + \
	"<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/>" + \
	"</Relationships>"

const _PPTX_SLIDE_RELS := "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + \
	"<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">" + \
	"<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>" + \
	"</Relationships>"


static func _zip_write(zip: ZIPPacker, path: String, text: String) -> void:
	zip.start_file(path)
	zip.write_file(text.to_utf8_buffer())
	zip.close_file()


static func _pptx_core_xml(title: String) -> String:
	var iso := Time.get_datetime_string_from_system(true) + "Z"
	return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + \
		"<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">" + \
		"<dc:title>" + _escape(title) + "</dc:title>" + \
		"<dc:creator>Office Plus One</dc:creator>" + \
		"<cp:lastModifiedBy>Office Plus One</cp:lastModifiedBy>" + \
		"<dcterms:created xsi:type=\"dcterms:W3CDTF\">" + iso + "</dcterms:created>" + \
		"<dcterms:modified xsi:type=\"dcterms:W3CDTF\">" + iso + "</dcterms:modified>" + \
		"</cp:coreProperties>"


static func _pptx_app_xml(slide_count: int) -> String:
	return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + \
		"<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\" xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\">" + \
		"<Application>Office Plus One Exporter</Application>" + \
		"<PresentationFormat>On-screen Show (4:3)</PresentationFormat>" + \
		"<Slides>" + str(slide_count) + "</Slides>" + \
		"<Company></Company>" + \
		"</Properties>"


static func _pptx_slide_xml(slide: Dictionary) -> String:
	var bullets: Array = slide.get("bullets", [])
	var body_paragraphs := ""
	if bullets.is_empty():
		body_paragraphs = "<a:p><a:endParaRPr lang=\"en-US\" sz=\"2000\"/></a:p>"
	else:
		for b in bullets:
			body_paragraphs += "<a:p><a:r><a:rPr lang=\"en-US\" sz=\"2000\"/><a:t>" + \
				_escape(b) + "</a:t></a:r></a:p>"

	var title_text := _escape(slide.get("title", ""))

	return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + \
		"<p:sld xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\">" + \
		"<p:cSld><p:spTree>" + \
		"<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>" + \
		"<p:grpSpPr/>" + \
		"<p:sp>" + \
		"<p:nvSpPr><p:cNvPr id=\"2\" name=\"Title\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr>" + \
		"<p:spPr><a:xfrm><a:off x=\"457200\" y=\"274638\"/><a:ext cx=\"8229600\" cy=\"1143000\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr>" + \
		"<p:txBody><a:bodyPr wrap=\"square\"><a:noAutofit/></a:bodyPr><a:lstStyle/>" + \
		"<a:p><a:r><a:rPr lang=\"en-US\" sz=\"3200\" b=\"1\"/><a:t>" + title_text + "</a:t></a:r></a:p>" + \
		"</p:txBody>" + \
		"</p:sp>" + \
		"<p:sp>" + \
		"<p:nvSpPr><p:cNvPr id=\"3\" name=\"Content\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr>" + \
		"<p:spPr><a:xfrm><a:off x=\"457200\" y=\"1600200\"/><a:ext cx=\"8229600\" cy=\"4525963\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr>" + \
		"<p:txBody><a:bodyPr wrap=\"square\"><a:normAutofit/></a:bodyPr><a:lstStyle/>" + \
		body_paragraphs + \
		"</p:txBody>" + \
		"</p:sp>" + \
		"</p:spTree></p:cSld>" + \
		"<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>" + \
		"</p:sld>"


## Builds a minimal but valid .pptx via ZIPPacker (staged to a temp file
## under user:// then read back, since ZIPPacker can't write to memory).
## Returns an empty PackedByteArray if the zip could not be produced.
static func _build_pptx(title: String, slides: Array[Dictionary]) -> PackedByteArray:
	var decks := slides
	if decks.is_empty():
		decks = [{"title": title, "bullets": [], "notes": "", "svg": ""}]
	var n := decks.size()

	var content_types: Array[String] = [
		"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>",
		"<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">",
		"<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>",
		"<Default Extension=\"xml\" ContentType=\"application/xml\"/>",
		"<Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/>",
		"<Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/>",
		"<Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/>",
		"<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>",
		"<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>",
		"<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>",
	]
	for i in range(n):
		content_types.append(
			"<Override PartName=\"/ppt/slides/slide%d.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>" % (i + 1)
		)
	content_types.append("</Types>")

	var sld_ids: Array[String] = []
	var pres_rels: Array[String] = [
		"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>",
		"<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">",
		"<Relationship Id=\"rIdM\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/>",
	]
	for i in range(n):
		sld_ids.append("<p:sldId id=\"%d\" r:id=\"rIdS%d\"/>" % [256 + i, i + 1])
		pres_rels.append(
			"<Relationship Id=\"rIdS%d\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide%d.xml\"/>" % [i + 1, i + 1]
		)
	pres_rels.append("</Relationships>")

	var pres_xml := "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + \
		"<p:presentation xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\">" + \
		"<p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rIdM\"/></p:sldMasterIdLst>" + \
		"<p:sldIdLst>" + "".join(sld_ids) + "</p:sldIdLst>" + \
		"<p:sldSz cx=\"9144000\" cy=\"6858000\" type=\"screen4x3\"/>" + \
		"<p:notesSz cx=\"6858000\" cy=\"9144000\"/>" + \
		"</p:presentation>"

	var zip := ZIPPacker.new()
	var tmp_path := "user://_export_tmp_%d.pptx" % Time.get_ticks_usec()
	if zip.open(tmp_path) != OK:
		return PackedByteArray()

	_zip_write(zip, "[Content_Types].xml", "".join(content_types))
	_zip_write(zip, "_rels/.rels", _PPTX_RELS_ROOT)
	_zip_write(zip, "docProps/core.xml", _pptx_core_xml(title))
	_zip_write(zip, "docProps/app.xml", _pptx_app_xml(n))
	_zip_write(zip, "ppt/presentation.xml", pres_xml)
	_zip_write(zip, "ppt/_rels/presentation.xml.rels", "".join(pres_rels))
	_zip_write(zip, "ppt/theme/theme1.xml", _PPTX_THEME)
	_zip_write(zip, "ppt/slideMasters/slideMaster1.xml", _PPTX_SLIDE_MASTER)
	_zip_write(zip, "ppt/slideMasters/_rels/slideMaster1.xml.rels", _PPTX_SLIDE_MASTER_RELS)
	_zip_write(zip, "ppt/slideLayouts/slideLayout1.xml", _PPTX_SLIDE_LAYOUT)
	_zip_write(zip, "ppt/slideLayouts/_rels/slideLayout1.xml.rels", _PPTX_SLIDE_LAYOUT_RELS)
	for i in range(n):
		_zip_write(zip, "ppt/slides/slide%d.xml" % (i + 1), _pptx_slide_xml(decks[i]))
		_zip_write(zip, "ppt/slides/_rels/slide%d.xml.rels" % (i + 1), _PPTX_SLIDE_RELS)

	var close_err := zip.close()
	if close_err != OK:
		return PackedByteArray()

	var bytes := FileAccess.get_file_as_bytes(tmp_path)
	var dir := DirAccess.open("user://")
	if dir:
		dir.remove(tmp_path.trim_prefix("user://"))
	return bytes

#endregion


#region saving

## Writes `file` under user://exports, and on desktop also copies it to
## ~/Documents/OfficePlusOne (creating the directory as needed). Returns
## the most useful absolute path: the Documents copy on desktop, or the
## globalized user:// path on Android. Colliding names get " (2)", " (3)", ...
static func save_local(file: Dictionary) -> String:
	var filename := sanitize_filename(str(file.get("filename", "export.txt")))
	var raw_bytes = file.get("bytes", PackedByteArray())
	var bytes: PackedByteArray = raw_bytes if raw_bytes is PackedByteArray else PackedByteArray()

	var staging_dir := export_dir()
	DirAccess.make_dir_recursive_absolute(staging_dir)

	var is_android := OS.get_name() == "Android"
	var docs_dir := ""
	if not is_android:
		var docs_base := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
		# Some headless/minimal environments (no XDG user-dirs configured)
		# return "". Guard against turning that into a relative path.
		if docs_base != "" and docs_base.is_absolute_path():
			docs_dir = docs_base.path_join(DOCUMENTS_SUBDIR)
			DirAccess.make_dir_recursive_absolute(docs_dir)

	var check_dirs: Array[String] = [staging_dir]
	if docs_dir != "":
		check_dirs.append(docs_dir)
	var unique_name := _dedupe_name(check_dirs, filename)

	_write_bytes(staging_dir.path_join(unique_name), bytes)

	if docs_dir != "":
		var doc_path := docs_dir.path_join(unique_name)
		_write_bytes(doc_path, bytes)
		return ProjectSettings.globalize_path(doc_path)

	return ProjectSettings.globalize_path(staging_dir.path_join(unique_name))


static func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_buffer(bytes)
		f.close()


static func _dedupe_name(dirs: Array[String], filename: String) -> String:
	var base := filename.get_basename()
	var ext := filename.get_extension()
	var ext_suffix := ("." + ext) if ext != "" else ""
	var candidate := filename
	var n := 1
	while _exists_in_any(dirs, candidate):
		n += 1
		candidate = "%s (%d)%s" % [base, n, ext_suffix]
	return candidate


static func _exists_in_any(dirs: Array[String], filename: String) -> bool:
	for d in dirs:
		if FileAccess.file_exists(d.path_join(filename)):
			return true
	return false

#endregion
