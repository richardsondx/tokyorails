# -*- encoding : utf-8 -*-
# This module contains all tasks related to the Meetup API that are called via
# a scheduled task.
module Tokyorails::MeetupTasks

  # Import/update members from meetup.com
  #
  # This method will import new members and update existing members if their
  # meetup profile is newer. It will also delete any members no longer in the
  # meetup group
  #
  # It should not be called directly but should be called via a rake task
  # @example
  #   rake meetup:import_members
  # @see http://www.meetup.com/meetup_api/docs/2/profiles/ Meetup Profiles API
  #   documentation
  def self.import_members

    meetup_member_list = get_meetup_api('https://api.meetup.com/2/profiles.json')
    return unless meetup_member_list
    present_members = []
    meetup_member_list.each do |meetup_member|

      present_members << meetup_member['member_id'].to_s
      member = Member.where(:uid => meetup_member['member_id'].to_s).first

      if member.nil?
        update_member(Member.new, meetup_member)
      else
        # Meetups API doesn't use proper unix time, they use milliseconds for
        # some reason instead so we need to divide by 1000 before converting
        update_member(member, meetup_member) if member.updated_at < Time.zone.at((meetup_member['updated'].to_i / 1000))
      end
    end

    Member.where(Arel::Table.new(:members)[:uid].not_in present_members).destroy_all

  end

  def self.import_events
    event_list = get_meetup_api('https://api.meetup.com/2/events.json', :status => 'upcoming,past')
    if event_list.present?
      event_list.each do |api_event|
        event = Event.find_or_initialize_by_uid(api_event['id'].to_s)
        # only update upcoming or previously unknown events
        unless event.status == 'past'
          event.name = api_event['name']
          event.status = api_event['status']
          event.time = Time.at(api_event['time'].to_i / 1000)
          venue = api_event['venue']
          event.address = "#{venue['name']}, #{venue['address_1']}, #{venue['address_2']}, #{venue['city']}"
          event.description = api_event['description']
          event.yes_rsvp_count = api_event['yes_rsvp_count']
          event.save

          import_rsvps_for_event(event.uid)
        end
      end
    end
  end

  def self.import_rsvps_for_event(event_uid)
    rsvp_list = get_meetup_api('https://api.meetup.com/2/rsvps.json', :event_id => event_uid)
    if rsvp_list.present?
      rsvp_list.each do |api_rsvp|
        rsvp = Rsvp.find_or_initialize_by_uid(api_rsvp['rsvp_id'].to_s)
        rsvp.response = api_rsvp['response']
        rsvp.member_id = api_rsvp['member']['member_id']
        rsvp.guests = api_rsvp['guests']
        rsvp.meetup_id = api_rsvp['event']['id']
        rsvp.modified_at = Time.at(api_rsvp['mtime'].to_i / 1000)
        rsvp.save
      end
    end
  end

  protected

  # Update a single member record
  #
  # @param [Member] record An instance of the {Member} class
  # @param [Hash] data The data to use to update this member, see the meetup
  #  API documentation for a list of attributes
  def self.update_member(record, data)
      record.uid = data['member_id']
      record.name = data['name']
      record.bio = data['bio'] || "I have no bio."
      record.photo_url = data['photo_url']
      record.github_username = get_github_username(data['additional'])
      record.image.destroy if record.image && record.photo_url_changed?
      record.save!
  end

  # Retrieve data from Meetup API
  #
  # @return [Array] An array of hashes; each one represents a meetup item
  # @note currently hardcoded to retrieve a maximum of 250 items, should
  #   probably improve to retrieve all members in batches etc.
  def self.get_meetup_api(endpoint, params = {})

    uri = URI(endpoint)
    uri.query = URI.encode_www_form( { :key => Rails.application.config.meetup_com_api_key, :page => 250, :group_id => '2270561'}.merge(params))
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Get.new(uri.path + '?' + uri.query)
    response = http.start {|http| http.request(request) }

    # Due to this issue: http://redmine.ruby-lang.org/issues/2567 net/http does
    # not detect the meetup response encoding correctly so it buggers up the
    # character encoding of some of our nordicly-named members.
    #
    # So first we have to force the correct encoding (ISO-8859-1) THEN change it
    # to UTF-8 which is what this site is using.
    encoded_response = response.body.force_encoding(Encoding::ISO_8859_1).encode(Encoding::UTF_8)
    JSON.parse(encoded_response)['results']
    rescue => e
      Airbrake.notify(e)
      nil

  end

  # Parse out the github username for this member
  #
  # This method will search a string starting with "github:" and capture all
  # characters until the first whitespace character. It will always return the
  # first match if multiple are found.
  #
  # @param [String] string The string to parse for a github username
  # @return [String, Nil]
  # @example
  #   >> get_github_username("github:rurounijones")
  #   => "rurounijones"
  #
  #   >> get_github_username("github:rurouni-jones123 I am a github user!")
  #   => "rurouni-jones123"
  #
  #   >> get_github_username("github:rurounijones github:rurounijones2")
  #   => "rurounijones"
  #
  #   >> get_github_username("No github users here I am afraid")
  #   => nil
  def self.get_github_username(string)
      match = /github:([^\s]*)/.match(string)

      # Return the first match if there is one, otherwise nil
      match ? match[1] : nil
  end
end
