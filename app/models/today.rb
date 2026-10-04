module Today
  def self.said
    "Today is #{Date.current.strftime('%A, %B %-d, %Y')}. Anything dated before it is in the past, " \
      "and anything dated after it is still to come."
  end

  def self.spans(on = Date.current)
    month = on.beginning_of_month
    quarter = on.beginning_of_quarter

    "This month is #{month.strftime('%B %Y')}, and last month was #{month.prev_month.strftime('%B %Y')}. " \
      "This quarter runs from #{spanned(quarter)}, and last quarter ran from #{spanned(quarter.prev_month(3))}. " \
      "This year is #{on.year}, and last year was #{on.year - 1}."
  end

  def self.spanned(start)
    "#{start.strftime('%B %-d')} to #{start.end_of_quarter.strftime('%B %-d, %Y')}"
  end
end
