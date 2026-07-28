///|
async fn main {
  // Step 2/3: register the labeler extension for folder + image ops.
  @proton.config("moon.proton")
  .extension(@labeler.extension())
  .run_or_abort()
}
