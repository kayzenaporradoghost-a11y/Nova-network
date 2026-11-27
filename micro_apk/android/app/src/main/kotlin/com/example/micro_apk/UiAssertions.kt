package com.example.micro_apk

internal sealed class UiAssertion {
    data class PackageIs(val value: String) : UiAssertion()
    data class TextContains(val value: String) : UiAssertion()
    data class EditableExists(val value: Boolean) : UiAssertion()
    data class ElementExists(val selector: UiSelector) : UiAssertion()
    data class ElementAbsent(val selector: UiSelector) : UiAssertion()
}

internal object UiAssert {
    fun evaluate(index: UiIndex, assertion: UiAssertion): Boolean = when (assertion) {
        is UiAssertion.PackageIs -> index.packageName == assertion.value
        is UiAssertion.TextContains -> index.elements.any {
            it.label?.contains(assertion.value, ignoreCase = true) == true
        }
        is UiAssertion.EditableExists -> index.elements.any { it.editable } == assertion.value
        is UiAssertion.ElementExists -> index.resolve(assertion.selector).first != null
        is UiAssertion.ElementAbsent -> index.resolve(assertion.selector).first == null
    }

    fun all(index: UiIndex, assertions: List<UiAssertion>): Boolean =
        assertions.all { evaluate(index, it) }
}
