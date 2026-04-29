// Stubs for SanitizerCoverage symbols missing when C vendor files
// (dvui's stb/tinyfiledialogs) are compiled with --fuzz coverage instrumentation.
void __sanitizer_cov_trace_const_cmp1(void) {}
void __sanitizer_cov_trace_const_cmp2(void) {}
void __sanitizer_cov_trace_const_cmp4(void) {}
void __sanitizer_cov_trace_const_cmp8(void) {}
void __sanitizer_cov_trace_cmp1(void) {}
void __sanitizer_cov_trace_cmp2(void) {}
void __sanitizer_cov_trace_cmp4(void) {}
void __sanitizer_cov_trace_cmp8(void) {}
void __sanitizer_cov_trace_switch(void) {}
void __sanitizer_cov_trace_div4(void) {}
void __sanitizer_cov_trace_div8(void) {}
void __sanitizer_cov_trace_gep(void) {}
void __sanitizer_cov_trace_pc(void) {}
void __sanitizer_cov_trace_pc_guard(void) {}
void __sanitizer_cov_trace_pc_guard_init(void) {}