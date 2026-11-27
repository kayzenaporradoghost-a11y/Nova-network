package com.example.micro_apk

import android.graphics.Rect
import android.view.accessibility.AccessibilityNodeInfo
import java.security.MessageDigest
import java.util.Locale

internal data class UiSelector(
    val cls: String = "",
    val rid: String? = null,
    val label: String? = null,
    val bounds: Rect = Rect()
) {
    fun score(element: UiElement): Int {
        var score = 0
        if (!rid.isNullOrBlank() && element.rid == rid) score += 60
        if (!label.isNullOrBlank()) {
            if (element.label.equals(label, true)) score += 40
            else if (element.label?.contains(label, true) == true) score += 20
        }
        if (cls.isNotBlank() && element.cls == cls) score += 10
        if (!bounds.isEmpty && Rect.intersects(bounds, element.bounds)) score += 15
        if (element.clickable || element.editable) score += 5
        return score
    }
}

internal data class UiElement(
    val cls: String,
    val rid: String?,
    val text: String?,
    val description: String?,
    val bounds: Rect,
    val clickable: Boolean,
    val editable: Boolean,
    val scrollable: Boolean,
    val volatile: Boolean,
    val depth: Int
) {
    val label: String? get() = text ?: description
    fun selector() = UiSelector(cls, rid, label, Rect(bounds))
}

internal object UiVolatile {
    private val resourcePattern = Regex("badge|unread|timestamp|time|clock|typing|progress|avatar|dot", RegexOption.IGNORE_CASE)
    private val textPattern = Regex("""^(\d{1,2}[:h]\d{2}|ontem|hoje|yesterday|today|digitando.*|typing.*|online|visto.*|last seen.*)$""", RegexOption.IGNORE_CASE)
    fun matches(rid: String?, text: String?) =
        resourcePattern.containsMatchIn(rid.orEmpty()) || textPattern.matches(text.orEmpty().trim())
}

internal class UiIndex(private val root: AccessibilityNodeInfo?) {
    val rawNodeCount: Int
    val elements: List<UiElement>
    val packageName: String?

    init {
        packageName = root?.packageName?.toString()
        var raw = 0
        val output = ArrayList<UiElement>(60)
        fun walk(node: AccessibilityNodeInfo?, depth: Int) {
            if (node == null || depth > 6) return
            raw++
            val text = node.text?.toString()?.trim()?.takeIf { it.isNotEmpty() }
            val description = node.contentDescription?.toString()?.trim()?.takeIf { it.isNotEmpty() }
            val bounds = Rect().also { node.getBoundsInScreen(it) }
            val useful = text != null || description != null || node.isClickable || node.isEditable || node.isScrollable
            if (useful && !bounds.isEmpty && output.size < 60) {
                val rid = node.viewIdResourceName?.substringAfterLast('/')
                output += UiElement(
                    node.className?.toString().orEmpty(), rid, text, description, bounds,
                    node.isClickable, node.isEditable, node.isScrollable,
                    UiVolatile.matches(rid, text), depth
                )
            }
            for (i in 0 until node.childCount) {
                if (output.size >= 60) break
                walk(node.getChild(i), depth + 1)
            }
        }
        walk(root, 0)
        rawNodeCount = raw
        elements = output.sortedBy { it.bounds.top }
    }

    fun resolve(selector: UiSelector, minimum: Int = 45): Pair<UiElement?, Int> {
        val matches = elements.map { it to selector.score(it) }.filter { it.second >= minimum }
        if (matches.isEmpty()) return null to 0
        val bestScore = matches.maxOf { it.second }
        val best = matches.filter { it.second == bestScore }
        return (if (best.size == 1) best[0].first else null) to best.size
    }

    fun skeleton(): String = digest(elements.filterNot { it.volatile }.joinToString("|") {
        "${it.cls}#${it.rid}#${it.label}#${it.bounds.left / 8},${it.bounds.top / 8},${it.bounds.right / 8},${it.bounds.bottom / 8}#${it.clickable}"
    })

    fun summary(): String = buildString {
        append("APP: ").append(packageName ?: "desconhecido").append('\n')
        append("NODE_COUNT_RAW: ").append(rawNodeCount).append('\n')
        append("NODE_COUNT_FILTERED: ").append(elements.size).append('\n')
        append("SKELETON: ").append(skeleton()).append('\n')
        elements.forEachIndexed { i, e ->
            append("ELEMENTO ").append(i + 1)
                .append(" texto=").append(e.text.orEmpty().take(240))
                .append(" descrição=").append(e.description.orEmpty().take(160))
                .append(" classe=").append(e.cls)
                .append(" rid=").append(e.rid.orEmpty())
                .append(" bounds=").append(e.bounds.flattenToString())
                .append(" clicável=").append(e.clickable)
                .append(" rolável=").append(e.scrollable)
                .append(" editável=").append(e.editable).append('\n')
        }
        if (elements.isEmpty()) append("Nenhum elemento acessível exposto pelo app atual.")
    }.take(16000)

    companion object {
        fun digest(value: String): String = MessageDigest.getInstance("SHA-1")
            .digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(Locale.ROOT, it) }
    }
}
